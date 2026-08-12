import CoreLocation
import Foundation
import Observation

/// Posted speed limits, from two real sources — never inferred.
///
/// Why not Google: the Roads API's `speedLimits` method is gated behind an Asset Tracking
/// licence — with billing fully active it still returns `API_KEY_SERVICE_BLOCKED` for
/// `ListSpeedLimits` specifically, so no amount of normal spend unlocks it. MapKit exposes no
/// speed limit API to third-party apps at all.
///
/// 1. **OpenStreetMap** (Overpass API) — worldwide, free, keyless. Good coverage on highways and
///    arterials, but frequently blank on residential streets. Measured directly: McKibbin St in
///    Brooklyn carries no `maxspeed` tag at all, which is why the sign never appeared there.
/// 2. **NYC DOT** (`VZV Speed Limits` on NYC Open Data) — the city's own posted-limit centreline
///    data, which *does* cover those residential streets. Only queried inside NYC's bounding box.
///
/// Both are real posted limits. When neither has data the sign simply doesn't appear — it never
/// guesses or falls back to a default.
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
    /// it: at most one request every 10s, and only after moving 80m — about one city block, so a
    /// turn onto a new street resolves quickly without firing on every GPS tick.
    func refreshIfNeeded(at location: CLLocation) async {
        let now = Date()
        guard now.timeIntervalSince(lastFetch) >= 10 else { return }
        if let last = lastCoordinate {
            let moved = location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard moved >= 80 else { return }
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

            if let best {
                speedLimitKph = best.kph
                return
            }
            // OSM answered but has no maxspeed for this road — try the city's own data.
            speedLimitKph = await cityFallback(around: coordinate)
        } catch {
            // A network hiccup isn't evidence the limit changed, so keep the last reading up
            // unless the city source can positively replace it.
            if let city = await cityFallback(around: coordinate) {
                speedLimitKph = city
            }
        }
    }

    private func cityFallback(around coordinate: CLLocationCoordinate2D) async -> Int? {
        guard Self.isWithinNYC(coordinate) else { return nil }
        return await nycSpeedLimit(around: coordinate)
    }

    /// NYC DOT posts limits per street centreline segment. A 60m circle is wide enough to catch
    /// the segment when GPS puts you slightly off the centreline, narrow enough not to reach the
    /// next street over.
    private func nycSpeedLimit(around coordinate: CLLocationCoordinate2D) async -> Int? {
        var components = URLComponents(string: "https://data.cityofnewyork.us/resource/5mad-ntua.json")
        components?.queryItems = [
            URLQueryItem(name: "$where", value: "within_circle(the_geom, \(coordinate.latitude), \(coordinate.longitude), 60)"),
            URLQueryItem(name: "$select", value: "postvz_sl"),
            URLQueryItem(name: "$limit", value: "5")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard !Task.isCancelled else { return nil }
            let rows = try JSONDecoder().decode([NYCSpeedLimitRow].self, from: data)
            // Lowest posted limit among overlapping segments is the safe one to show.
            let mph = rows.compactMap { Int($0.postvz_sl ?? "") }.filter { $0 > 0 }.min()
            guard let mph else { return nil }
            return Int((Double(mph) * 1.60934).rounded())
        } catch {
            return nil
        }
    }

    /// Rough bounding box covering the five boroughs.
    private static func isWithinNYC(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (40.47...40.93).contains(coordinate.latitude) && (-74.28...(-73.68)).contains(coordinate.longitude)
    }

    private struct NYCSpeedLimitRow: Decodable {
        let postvz_sl: String?
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
