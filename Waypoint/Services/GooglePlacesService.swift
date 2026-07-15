import CoreLocation
import Foundation

enum GooglePlacesError: Error {
    case missingAPIKey
    case noMatch
    case requestFailed(Int)
}

struct GooglePlacesService {
    private static let detailFields = [
        "id", "displayName", "primaryTypeDisplayName", "formattedAddress",
        "internationalPhoneNumber", "websiteUri", "rating", "userRatingCount",
        "businessStatus", "currentOpeningHours", "photos", "reviews",
    ].joined(separator: ",")

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey ?? Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
        self.session = session
    }

    /// Resolves a MapKit search result to Google's richer place data by text-searching on name + location,
    /// then fetching full details for the best match.
    func findPlace(name: String, coordinate: CLLocationCoordinate2D) async throws -> GooglePlace {
        guard !apiKey.isEmpty else { throw GooglePlacesError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchText")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("places.id", forHTTPHeaderField: "X-Goog-FieldMask")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "textQuery": name,
            "locationBias": [
                "circle": [
                    "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                    "radius": 200,
                ]
            ],
        ])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let decoded = try JSONDecoder().decode(TextSearchResponse.self, from: data)
        guard let placeId = decoded.places?.first?.id else {
            throw GooglePlacesError.noMatch
        }
        return try await placeDetails(placeId: placeId)
    }

    func placeDetails(placeId: String) async throws -> GooglePlace {
        guard !apiKey.isEmpty else { throw GooglePlacesError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places/\(placeId)")!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.detailFields, forHTTPHeaderField: "X-Goog-FieldMask")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try JSONDecoder().decode(GooglePlace.self, from: data)
    }

    func photoURL(photoName: String, maxWidthPx: Int = 800) -> URL? {
        guard !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://places.googleapis.com/v1/\(photoName)/media")
        components?.queryItems = [
            URLQueryItem(name: "maxWidthPx", value: String(maxWidthPx)),
            URLQueryItem(name: "key", value: apiKey),
        ]
        return components?.url
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GooglePlacesError.requestFailed(status)
        }
    }
}

private struct TextSearchResponse: Codable {
    struct PlaceRef: Codable {
        let id: String
    }

    let places: [PlaceRef]?
}
