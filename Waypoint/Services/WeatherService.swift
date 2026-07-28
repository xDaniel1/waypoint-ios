import CoreLocation
import Observation
import WeatherKit

@Observable
@MainActor
final class WeatherService {
    private(set) var temperature: String?
    private(set) var symbolName: String?
    private(set) var errorMessage: String?
    private(set) var airQualityIndex: Int?

    private let weatherKitService = WeatherKit.WeatherService.shared
    private let googleWeatherService = GoogleWeatherService()
    private let airQualityService = GoogleAirQualityService()

    func refresh(for location: CLLocation) async {
        // Google Weather is the primary source: WeatherKit needs a server-side entitlement
        // that can take hours to propagate after first enabling, so it's only a fallback.
        do {
            let reading = try await googleWeatherService.currentConditions(at: location.coordinate)
            temperature = Self.formatCelsius(reading.temperatureCelsius)
            symbolName = reading.symbolName
            errorMessage = nil
        } catch {
            print("Google Weather error: \(error)")
            await refreshFromWeatherKit(location)
        }

        // Air quality is Google-sourced since neither weather source exposes an AQI.
        do {
            airQualityIndex = try await airQualityService.currentConditions(at: location.coordinate).aqi
        } catch {
            airQualityIndex = nil
            print("Air Quality error: \(error)")
        }
    }

    private func refreshFromWeatherKit(_ location: CLLocation) async {
        do {
            let weather = try await weatherKitService.weather(for: location)
            temperature = weather.currentWeather.temperature.formatted(
                .measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0)))
            )
            symbolName = weather.currentWeather.symbolName
            errorMessage = nil
        } catch {
            temperature = nil
            symbolName = nil
            errorMessage = "Weather unavailable"
            print("WeatherKit error: \(error)")
        }
    }

    /// Formats using the device's locale so users on Fahrenheit see °F even though Google returns °C.
    private static func formatCelsius(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
