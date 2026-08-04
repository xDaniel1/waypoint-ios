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

        var components = URLComponents(string: "https://weather.googleapis.com/v1/currentConditions:lookup")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "location.latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "location.longitude", value: String(coordinate.longitude)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        GoogleAPIRequest.addBundleIdentifierHeader(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleWeatherError.requestFailed(status)
        }
        let decoded = try JSONDecoder().decode(CurrentConditions.self, from: data)
        return GoogleWeatherReading(
            temperatureCelsius: decoded.temperature.degrees,
            symbolName: Self.symbol(for: decoded.weatherCondition?.type, isDaytime: decoded.isDaytime ?? true)
        )
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
