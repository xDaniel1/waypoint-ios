import CoreLocation
import Observation
import OSLog
import WeatherKit

@Observable
@MainActor
final class WeatherService {
    private(set) var temperature: String?
    private(set) var symbolName: String?
    private(set) var errorMessage: String?
    private(set) var airQualityIndex: Int?

    private let weatherKitService = WeatherKit.WeatherService.shared

    func refresh(for location: CLLocation) async {
        do {
            let weather = try await weatherKitService.weather(for: location)
            temperature = weather.currentWeather.temperature.formatted(
                .measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0)))
            )
            symbolName = weather.currentWeather.symbolName
            errorMessage = nil
            airQualityIndex = nil // Air quality is dropped to remove Google API cost
        } catch {
            // WeatherKit needs a working service token, and it fails outright in the simulator
            // and intermittently on device. Open-Meteo is free, keyless and unmetered, so it
            // backs the widget up rather than leaving it blank — the app already had the widget,
            // the service, and the entitlement, and still showed nothing when this threw.
            Logger.places.error("WeatherKit failed, falling back: \(error.localizedDescription)")
            await loadFallback(for: location)
        }
    }

    private func loadFallback(for location: CLLocation) async {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: usesFahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = components?.url,
              let data = try? await URLSession.shared.data(from: url).0,
              let decoded = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data),
              let reading = decoded.current else {
            temperature = nil
            symbolName = nil
            errorMessage = "Weather unavailable"
            return
        }

        temperature = "\(Int(reading.temperature_2m.rounded()))°"
        symbolName = Self.symbol(forWMOCode: reading.weather_code)
        errorMessage = nil
        airQualityIndex = nil
    }

    private var usesFahrenheit: Bool {
        Locale.current.measurementSystem != .metric
    }

    /// WMO weather codes mapped to the SF Symbols the widget already draws.
    private static func symbol(forWMOCode code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    private struct OpenMeteoResponse: Decodable {
        let current: Current?
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
    }
}

extension WeatherService {
    /// Whether a fetch has actually produced conditions, so callers can retry until it has
    /// rather than assuming the first attempt worked.
    var hasCurrentConditions: Bool {
        temperature != nil && symbolName != nil
    }
}
