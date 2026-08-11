import CoreLocation
import Foundation
import Observation

/// Posted speed limits from OpenStreetMap via the Overpass API.
///
/// Why not Google: the Roads API's `speedLimits` method is gated behind an Asset Tracking
/// licence — with billing fully active it still returns `API_KEY_SERVICE_BLOCKED` for
/// `ListSpeedLimits` specifically, so no amount of normal spend unlocks it. MapKit exposes no
/// speed limit API to third-party apps at all. OSM is the one source that's actually reachable
/// here, and it's free and keyless.
///
/// Honest limitation: OSM `maxspeed` coverage is good on highways and major urban roads but
/// patchy on residential streets. When there's no tag for the road you're on, the sign simply
/// doesn't appear — it never guesses or falls back to a default limit.
@Observable
@MainActor
final class SpeedLimitService {
    private(set) var speedLimitKph: Int?

    private let session: URLSession
    private var lastFetch: Date = .distantPast
    private var lastCoordinate: CLLocationCoordinate2D?
    private var inFlight: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Converted for display in the device's own units.
    var display: (value: Int, unit: String)? {
        guard let speedLimitKph else { return nil }
        if usesMiles {
            return (Int((Double(speedLimitKph) * 0.621371).rounded()), "mph")
        }
        return (speedLimitKph, "km/h")
    }

    private var usesMiles: Bool {
        Locale.current.measurementSystem != .metric
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        speedLimitKph = nil
        lastFetch = .distantPast
        lastCoordinate = nil
    }

    /// Overpass is a free, shared, community-run endpoint, so this is deliberately gentle with
    /// it: at most one request every 15s, and only after moving 120m — roughly "you've plausibly
    /// turned onto a different road" rather than once per GPS tick.
    func refreshIfNeeded(at location: CLLocation) async {
        let now = Date()
        guard now.timeIntervalSince(lastFetch) >= 15 else { return }
        if let last = lastCoordinate {
            let moved = location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard moved >= 120 else { return }
        }
        lastFetch = now
        lastCoordinate = location.coordinate

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            await self?.fetch(around: location.coordinate)
        }
        await inFlight?.value
    }

    private func fetch(around coordinate: CLLocationCoordinate2D) async {
        // 25m radius keeps this to the road actually being driven rather than pulling in the
        // cross street at an intersection.
        let query = """
        [out:json][timeout:10];way(around:25,\(coordinate.latitude),\(coordinate.longitude))["maxspeed"];out tags 5;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            guard !Task.isCancelled else { return }
            let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)

            // Prefer the highest-classification road nearby: at an intersection the driver is far
            // more likely to be on the arterial than the side street.
            let best = decoded.elements
                .compactMap { element -> (rank: Int, kph: Int)? in
                    guard let raw = element.tags?["maxspeed"],
                          let kph = Self.parseMaxspeed(raw) else { return nil }
                    return (Self.roadRank(element.tags?["highway"]), kph)
                }
                .max { $0.rank < $1.rank }

            speedLimitKph = best?.kph
        } catch {
            // Leave the last known reading up rather than flickering the sign on a hiccup.
        }
    }

    /// OSM stores this as a free-text tag: "50" (implicitly km/h), "25 mph", "30 knots", or
    /// country presets like "US:urban" that carry no number at all. Only the forms with a real
    /// number are used; anything else is treated as unknown rather than guessed at.
    static func parseMaxspeed(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let number = value.prefix { $0.isNumber }
        guard let magnitude = Int(number), magnitude > 0 else { return nil }
        if value.contains("mph") {
            return Int((Double(magnitude) * 1.60934).rounded())
        }
        if value.contains("knot") { return nil }
        return magnitude  // OSM's default unit is km/h.
    }

    /// Rough OSM highway-classification ordering, biggest road first.
    private static func roadRank(_ highway: String?) -> Int {
        switch highway {
        case "motorway", "motorway_link": 6
        case "trunk", "trunk_link": 5
        case "primary", "primary_link": 4
        case "secondary", "secondary_link": 3
        case "tertiary", "tertiary_link": 2
        case "residential", "unclassified", "living_street": 1
        default: 0
        }
    }

    private struct OverpassResponse: Decodable {
        let elements: [Element]
        struct Element: Decodable {
            let tags: [String: String]?
        }
    }
}
