import CoreLocation
import Foundation
import Observation

/// Fetches posted speed limits from Google's Roads API for the current position.
///
/// Honest limitation: the `speedLimits` endpoint requires the Roads API to be enabled AND, per
/// Google's terms, an Asset Tracking / premium license. If either is missing the request fails
/// and the sign simply stays hidden rather than showing a guessed value.
@Observable
@MainActor
final class SpeedLimitService {
    private(set) var speedLimitKph: Int?
    private(set) var isUnavailable = false

    private let apiKey: String
    private let session: URLSession
    private var lastFetch: Date = .distantPast
    private var lastCoordinate: CLLocationCoordinate2D?

    init(apiKey: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey ?? Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
        self.session = session
    }

    /// Speed limit converted for display, respecting the device's locale.
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
        speedLimitKph = nil
        isUnavailable = false
        lastFetch = .distantPast
        lastCoordinate = nil
    }

    /// Throttled so we don't burn quota: refetch at most every 20s, and only after moving 150m.
    func refreshIfNeeded(at location: CLLocation) async {
        guard !apiKey.isEmpty, !isUnavailable else { return }
        let now = Date()
        if now.timeIntervalSince(lastFetch) < 20 { return }
        if let last = lastCoordinate {
            let moved = location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            if moved < 150 { return }
        }
        lastFetch = now
        lastCoordinate = location.coordinate

        var components = URLComponents(string: "https://roads.googleapis.com/v1/speedLimits")!
        components.queryItems = [
            URLQueryItem(name: "path", value: "\(location.coordinate.latitude),\(location.coordinate.longitude)"),
            URLQueryItem(name: "units", value: "KPH"),
            URLQueryItem(name: "key", value: apiKey),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        GoogleAPIRequest.addBundleIdentifierHeader(to: &request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 403 || http.statusCode == 404 {
                // Roads API disabled or not licensed — stop asking and keep the sign hidden.
                isUnavailable = true
                speedLimitKph = nil
                return
            }
            guard (200..<300).contains(http.statusCode) else { return }
            let decoded = try JSONDecoder().decode(SpeedLimitsResponse.self, from: data)
            if let limit = decoded.speedLimits?.first?.speedLimit {
                speedLimitKph = Int(limit.rounded())
            } else {
                speedLimitKph = nil
            }
        } catch {
            // Network hiccup — leave the previous reading in place rather than flickering.
        }
    }

    private struct SpeedLimitsResponse: Codable {
        let speedLimits: [Limit]?

        struct Limit: Codable {
            let speedLimit: Double?
        }
    }
}
