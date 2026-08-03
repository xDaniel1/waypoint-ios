import CoreLocation
import Foundation

enum GooglePlacesError: Error {
    case missingAPIKey
    case noMatch
    case requestFailed(Int)
}

/// Caches resolved place details in memory so reopening the same place — a favorite, a recent,
/// the same search result twice — costs zero additional Places API calls within the TTL. Google's
/// Place Details (New) with Contact + Atmosphere fields is the priciest tier we call, and without
/// this every re-tap of an already-seen place was a fresh Text Search + Details round trip.
private actor PlaceDetailsCache {
    static let shared = PlaceDetailsCache()

    private struct Entry {
        let place: GooglePlace
        let cachedAt: Date
    }

    /// An hour is long enough to absorb repeat taps in a session, short enough that hours/ratings
    /// don't go stale for a place someone keeps coming back to across a longer session.
    private let ttl: TimeInterval = 3600
    private var entriesByKey: [String: Entry] = [:]
    private var entriesByPlaceID: [String: Entry] = [:]

    func place(forKey key: String) -> GooglePlace? {
        guard let entry = entriesByKey[key], isFresh(entry) else { return nil }
        return entry.place
    }

    func place(forID id: String) -> GooglePlace? {
        guard let entry = entriesByPlaceID[id], isFresh(entry) else { return nil }
        return entry.place
    }

    func store(_ place: GooglePlace, forKey key: String?) {
        let entry = Entry(place: place, cachedAt: Date())
        entriesByPlaceID[place.id] = entry
        if let key { entriesByKey[key] = entry }
    }

    private func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.cachedAt) < ttl
    }

    /// Name + coordinate rounded to ~11m — the same resolution used for the Text Search bias
    /// radius, so two lookups of the same real-world place land on the same cache key.
    static func lookupKey(name: String, coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 10_000).rounded() / 10_000
        let lng = (coordinate.longitude * 10_000).rounded() / 10_000
        return "\(name.lowercased())|\(lat)|\(lng)"
    }
}

struct GooglePlacesService {
    private static let detailFields = [
        "id", "displayName", "primaryTypeDisplayName", "formattedAddress",
        "internationalPhoneNumber", "websiteUri", "rating", "userRatingCount",
        "businessStatus", "currentOpeningHours", "photos", "reviews", "editorialSummary",
        "location", "priceLevel", "googleMapsUri", "paymentOptions", "goodForChildren",
        "restroom", "outdoorSeating", "servesVegetarianFood", "takeout", "delivery", "dineIn",
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

        let key = PlaceDetailsCache.lookupKey(name: name, coordinate: coordinate)
        if let cached = await PlaceDetailsCache.shared.place(forKey: key) { return cached }

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
        let place = try await placeDetails(placeId: placeId)
        await PlaceDetailsCache.shared.store(place, forKey: key)
        return place
    }

    /// Nearby Search (New), ranked by popularity. Used for Trending/Suggested discovery sections.
    func searchNearby(
        includedTypes: [String],
        coordinate: CLLocationCoordinate2D,
        radius: Double = 2000,
        maxResults: Int = 8
    ) async throws -> [GooglePlace] {
        guard !apiKey.isEmpty else { throw GooglePlacesError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchNearby")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.id,places.displayName,places.primaryTypeDisplayName,places.rating,places.userRatingCount,places.photos,places.formattedAddress,places.location,places.currentOpeningHours.openNow",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "includedTypes": includedTypes,
            "maxResultCount": maxResults,
            "rankPreference": "POPULARITY",
            "locationRestriction": [
                "circle": [
                    "center": ["latitude": coordinate.latitude, "longitude": coordinate.longitude],
                    "radius": radius,
                ]
            ],
        ])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let decoded = try JSONDecoder().decode(NearbySearchResponse.self, from: data)
        return decoded.places ?? []
    }

    func placeDetails(placeId: String) async throws -> GooglePlace {
        guard !apiKey.isEmpty else { throw GooglePlacesError.missingAPIKey }

        if let cached = await PlaceDetailsCache.shared.place(forID: placeId) { return cached }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places/\(placeId)")!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.detailFields, forHTTPHeaderField: "X-Goog-FieldMask")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let place = try JSONDecoder().decode(GooglePlace.self, from: data)
        await PlaceDetailsCache.shared.store(place, forKey: nil)
        return place
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

private struct NearbySearchResponse: Codable {
    let places: [GooglePlace]?
}
