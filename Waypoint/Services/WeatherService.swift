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
            temperature = nil
            symbolName = nil
            errorMessage = "Weather unavailable"
            print("WeatherKit error: \(error)")
        }
    }
}
