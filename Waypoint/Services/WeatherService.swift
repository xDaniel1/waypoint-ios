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

    private let service = WeatherKit.WeatherService.shared
    private let airQualityService = GoogleAirQualityService()

    func refresh(for location: CLLocation) async {
        do {
            let weather = try await service.weather(for: location)
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

        // Air quality is Google-sourced since WeatherKit doesn't expose an AQI.
        do {
            airQualityIndex = try await airQualityService.currentConditions(at: location.coordinate).aqi
        } catch {
            airQualityIndex = nil
            print("Air Quality error: \(error)")
        }
    }
}
