import CoreLocation
import Foundation

enum GoogleAirQualityError: Error {
    case missingAPIKey
    case requestFailed(Int)
}

struct AirQualityReading {
    let aqi: Int
    let category: String
}

/// Caches AQI readings in memory for the same reason and TTL as `WeatherCache` — air quality
/// doesn't shift meaningfully minute to minute, so repeat widget refreshes near the same spot
/// shouldn't re-bill Google.
private actor AirQualityCache {
    static let shared = AirQualityCache()

    private struct Entry {
        let reading: AirQualityReading
        let cachedAt: Date
    }

    private let ttl: TimeInterval = 900
    private var entries: [String: Entry] = [:]

    func reading(forKey key: String) -> AirQualityReading? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.cachedAt) < ttl else { return nil }
        return entry.reading
    }

    func store(_ reading: AirQualityReading, forKey key: String) {
        entries[key] = Entry(reading: reading, cachedAt: Date())
    }

    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lng = (coordinate.longitude * 100).rounded() / 100
        return "\(lat)|\(lng)"
    }
}

/// Wraps Google's Air Quality API (currentConditions:lookup) for the universal AQI shown
/// in the weather widget. WeatherKit doesn't expose air quality, so this is Google-sourced.
struct GoogleAirQualityService {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey ?? Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
        self.session = session
    }

    func currentConditions(at coordinate: CLLocationCoordinate2D) async throws -> AirQualityReading {
        guard !apiKey.isEmpty else { throw GoogleAirQualityError.missingAPIKey }

        let key = AirQualityCache.key(for: coordinate)
        if let cached = await AirQualityCache.shared.reading(forKey: key) { return cached }

        var request = URLRequest(url: URL(string: "https://airquality.googleapis.com/v1/currentConditions:lookup?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue(Bundle.main.bundleIdentifier ?? "com.danielguzman.waypoint", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        GoogleAPIRequest.addBundleIdentifierHeader(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "location": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
            "universalAqi": true,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleAirQualityError.requestFailed(status)
        }
        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let index = decoded.indexes?.first else { throw GoogleAirQualityError.requestFailed(-1) }
        let reading = AirQualityReading(aqi: index.aqi, category: index.category ?? "")
        await AirQualityCache.shared.store(reading, forKey: key)
        return reading
    }

    private struct LookupResponse: Codable {
        let indexes: [Index]?

        struct Index: Codable {
            let aqi: Int
            let category: String?
        }
    }
}
