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

        var request = URLRequest(url: URL(string: "https://airquality.googleapis.com/v1/currentConditions:lookup?key=\(apiKey)")!)
        request.httpMethod = "POST"
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
        return AirQualityReading(aqi: index.aqi, category: index.category ?? "")
    }

    private struct LookupResponse: Codable {
        let indexes: [Index]?

        struct Index: Codable {
            let aqi: Int
            let category: String?
        }
    }
}
