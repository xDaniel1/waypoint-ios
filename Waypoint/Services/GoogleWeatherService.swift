import CoreLocation
import Foundation

enum GoogleWeatherError: Error {
    case missingAPIKey
    case requestFailed(Int)
}

struct GoogleWeatherReading {
    let temperatureCelsius: Double
    /// SF Symbol name mapped from Google's weather condition type.
    let symbolName: String
}

/// Caches current-conditions readings in memory so reopening the app or re-centering the map
/// near the same spot doesn't re-bill Google for weather that hasn't meaningfully changed.
/// 15 minutes is long enough to absorb repeat app opens in a session, short enough that the
/// widget doesn't show stale conditions on a longer drive.
private actor WeatherCache {
    static let shared = WeatherCache()

    private struct Entry {
        let reading: GoogleWeatherReading
        let cachedAt: Date
    }

    private let ttl: TimeInterval = 900
    private var entries: [String: Entry] = [:]

    func reading(forKey key: String) -> GoogleWeatherReading? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.cachedAt) < ttl else { return nil }
        return entry.reading
    }

    func store(_ reading: GoogleWeatherReading, forKey key: String) {
        entries[key] = Entry(reading: reading, cachedAt: Date())
    }

    /// Coordinate rounded to ~1km — weather doesn't vary meaningfully at finer resolution.
    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lng = (coordinate.longitude * 100).rounded() / 100
        return "\(lat)|\(lng)"
    }
}

/// Wraps Google's Weather API (currentConditions:lookup). Used instead of WeatherKit, which
/// requires an Apple-server-side entitlement propagation that can lag for hours after enabling.
struct GoogleWeatherService {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey ?? Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
        self.session = session
    }

    func currentConditions(at coordinate: CLLocationCoordinate2D) async throws -> GoogleWeatherReading {
        guard !apiKey.isEmpty else { throw GoogleWeatherError.missingAPIKey }

        let key = WeatherCache.key(for: coordinate)
        if let cached = await WeatherCache.shared.reading(forKey: key) { return cached }

        var components = URLComponents(string: "https://weather.googleapis.com/v1/currentConditions:lookup")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "location.latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "location.longitude", value: String(coordinate.longitude)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Bundle.main.bundleIdentifier ?? "com.danielguzman.waypoint", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.timeoutInterval = 12

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleWeatherError.requestFailed(status)
        }
        let decoded = try JSONDecoder().decode(CurrentConditions.self, from: data)
        let reading = GoogleWeatherReading(
            temperatureCelsius: decoded.temperature.degrees,
            symbolName: Self.symbol(for: decoded.weatherCondition?.type, isDaytime: decoded.isDaytime ?? true)
        )
        await WeatherCache.shared.store(reading, forKey: key)
        return reading
    }

    /// Maps Google's weather condition enum to the closest SF Symbol, day/night aware.
    private static func symbol(for type: String?, isDaytime: Bool) -> String {
        switch type {
        case "CLEAR", "MOSTLY_CLEAR":
            return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        case "PARTLY_CLOUDY":
            return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        case "MOSTLY_CLOUDY", "CLOUDY":
            return "cloud.fill"
        case "LIGHT_RAIN", "RAIN", "RAIN_SHOWERS", "SCATTERED_SHOWERS":
            return "cloud.rain.fill"
        case "HEAVY_RAIN", "RAIN_PERIODICALLY_HEAVY":
            return "cloud.heavyrain.fill"
        case "THUNDERSTORM", "SCATTERED_THUNDERSTORMS", "THUNDERSHOWER":
            return "cloud.bolt.rain.fill"
        case "SNOW", "LIGHT_SNOW", "HEAVY_SNOW", "SNOW_SHOWERS", "FLURRIES":
            return "cloud.snow.fill"
        case "FREEZING_RAIN", "SLEET", "HAIL", "WINTRY_MIX":
            return "cloud.sleet.fill"
        case "FOG", "HAZE", "MIST":
            return "cloud.fog.fill"
        case "WINDY", "WIND_AND_RAIN":
            return "wind"
        default:
            return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        }
    }

    private struct CurrentConditions: Codable {
        let temperature: Temperature
        let weatherCondition: WeatherCondition?
        let isDaytime: Bool?

        struct Temperature: Codable {
            let degrees: Double
        }

        struct WeatherCondition: Codable {
            let type: String?
        }
    }
}
