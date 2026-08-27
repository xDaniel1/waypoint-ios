import CoreLocation
import Foundation

enum GooglePlacesError: Error {
    case missingAPIKey
    case noMatch
    case requestFailed(Int)
}

/// The one remaining Google dependency in the app, deliberately scoped as narrowly as possible.
///
/// Everything cheap and high-volume — autocomplete, nearby search, routing, weather — runs on
/// Apple's free on-device APIs (`MKLocalSearch`, `MKDirections`, WeatherKit). But Apple exposes
/// no photos, ratings, reviews, hours or price to third-party apps at any price, so a place card
/// built purely on MapKit is just a name and a phone number. This fills exactly that gap.
///
/// Cost shape: billed once per place card actually opened, not per keystroke, and served from an
/// in-memory cache on repeat opens — which is what keeps this far cheaper than the original
/// all-Google setup, where autocomplete and routing were the real spend.
struct GooglePlacesService {
    /// Requested in one shot because Google bills the Details call by field tier, not per field:
    /// splitting these across two calls would cost more, not less.
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

    var isConfigured: Bool { !apiKey.isEmpty }

    /// Resolves a MapKit search result to Google's richer record: a cheap id-only Text Search to
    /// match the place, then one Details call for the content MapKit can't provide.
    func details(name: String, coordinate: CLLocationCoordinate2D) async throws -> DetailedPlace {
        guard isConfigured else { throw GooglePlacesError.missingAPIKey }

        let key = DetailsCache.lookupKey(name: name, coordinate: coordinate)
        if let cached = await DetailsCache.place(forKey: key) { return cached }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchText")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        GoogleAPIRequest.addBundleIdentifierHeader(to: &request)
        // id only: this call exists purely to turn a name+coordinate into a place ID, so asking
        // for any other field here would be billed for nothing.
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
        guard let placeID = try JSONDecoder().decode(TextSearchResponse.self, from: data).places?.first?.id else {
            throw GooglePlacesError.noMatch
        }

        let place = try await details(placeID: placeID)
        await DetailsCache.store(place, forKey: key)
        return place
    }

    func details(placeID: String) async throws -> DetailedPlace {
        guard isConfigured else { throw GooglePlacesError.missingAPIKey }
        if let cached = await DetailsCache.place(forID: placeID) { return cached }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places/\(placeID)")!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        GoogleAPIRequest.addBundleIdentifierHeader(to: &request)
        request.setValue(Self.detailFields, forHTTPHeaderField: "X-Goog-FieldMask")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        // DetailedPlace's Codable keys already mirror the Places v1 JSON exactly, so the API
        // response decodes straight into the model the place card is built against.
        let place = try JSONDecoder().decode(DetailedPlace.self, from: data)
        await DetailsCache.store(place, forKey: nil)
        return place
    }

    /// Nearby Search (New) for the discovery shelves, ranked by Google's own popularity signal.
    /// This is the one call that makes those shelves look like Apple's — it's the only source of
    /// photos, ratings, price and open/closed state for places the user hasn't opened yet.
    ///
    /// Kept deliberately cheap: it only fires when the search sheet is opened (never per
    /// keystroke), asks for a single page, and is cached for 10 minutes per rounded location.
    /// - Parameter primaryTypesOnly: `includedTypes` matches any place that merely *carries* one
    ///   of the types, which is why a "cafe" search returns bookshops and clothing stores that
    ///   happen to have a coffee counter. `includedPrimaryTypes` restricts to places whose main
    ///   business is that type — what a themed guide needs.
    func searchNearby(
        includedTypes: [String],
        coordinate: CLLocationCoordinate2D,
        radius: Double = 2000,
        maxResults: Int = 8,
        primaryTypesOnly: Bool = false,
        /// Set for results that don't meaningfully change day to day, so they cache for a week
        /// instead of a couple of hours.
        longLived: Bool = false
    ) async throws -> [DetailedPlace] {
        guard isConfigured else { throw GooglePlacesError.missingAPIKey }

        let key = NearbyCache.key(
            includedTypes: includedTypes,
            coordinate: coordinate,
            radius: radius,
            primaryTypesOnly: primaryTypesOnly
        )
        if let cached = await NearbyCache.places(forKey: key, longLived: longLived) { return cached }

        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchNearby")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        GoogleAPIRequest.addBundleIdentifierHeader(to: &request)
        request.setValue(
            [
                "places.id", "places.displayName", "places.primaryTypeDisplayName",
                "places.rating", "places.userRatingCount", "places.photos",
                "places.formattedAddress", "places.location", "places.priceLevel",
                "places.currentOpeningHours.openNow", "places.currentOpeningHours.periods",
            ].joined(separator: ","),
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            (primaryTypesOnly ? "includedPrimaryTypes" : "includedTypes"): includedTypes,
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
        let places = try JSONDecoder().decode(NearbyResponse.self, from: data).places ?? []
        await NearbyCache.store(places, forKey: key, longLived: longLived)
        return places
    }

    /// Photo media URLs need the bundle-ID header like every other call, which `AsyncImage` can't
    /// set — `GooglePhotoImage` fetches these manually for that reason.
    func photoURL(photoName: String, maxWidthPx: Int = 800) -> URL? {
        guard isConfigured else { return nil }
        var components = URLComponents(string: "https://places.googleapis.com/v1/\(photoName)/media")
        components?.queryItems = [
            URLQueryItem(name: "maxWidthPx", value: String(maxWidthPx)),
            URLQueryItem(name: "key", value: apiKey),
        ]
        return components?.url
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw GooglePlacesError.requestFailed(http.statusCode)
        }
    }

    private struct TextSearchResponse: Decodable {
        struct Place: Decodable { let id: String }
        let places: [Place]?
    }

    private struct NearbyResponse: Decodable {
        let places: [DetailedPlace]?
    }
}

/// Reopening the same place — a favorite, a recent, the same search result twice — costs zero
/// extra Details calls within the TTL. This is the main thing keeping the hybrid bill small.
/// Place details, persisted across launches — see `DiskCache`.
private enum DetailsCache {
    /// 6 hours: long enough that reopening the same place all day is free, short enough that
    /// ratings and opening hours don't drift far.
    private static let store = DiskCache<DetailedPlace>(name: "details", ttl: 6 * 3600)
    private static let byIDStore = DiskCache<DetailedPlace>(name: "details-by-id", ttl: 6 * 3600)

    static func place(forKey key: String) async -> DetailedPlace? {
        await store.value(forKey: key)
    }

    static func place(forID id: String) async -> DetailedPlace? {
        await byIDStore.value(forKey: id)
    }

    static func store(_ place: DetailedPlace, forKey key: String?) async {
        await byIDStore.store(place, forKey: place.id)
        if let key { await store.store(place, forKey: key) }
    }

    /// Name + coordinate rounded to ~11m, matching the Text Search bias radius, so two lookups of
    /// the same real-world place land on one cache key.
    static func lookupKey(name: String, coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 10_000).rounded() / 10_000
        let lng = (coordinate.longitude * 10_000).rounded() / 10_000
        return "\(name.lowercased())|\(lat)|\(lng)"
    }
}

/// Nearby results, persisted across launches. Guide and city-guide shelves are the bulk of the
/// billed Nearby Search volume and their contents barely move hour to hour, so 2 hours keeps a
/// relaunch free without letting open/closed state drift badly.
private enum NearbyCache {
    private static let store = DiskCache<[DetailedPlace]>(name: "nearby", ttl: 2 * 3600)
    /// City guides search fixed city-centre coordinates for landmarks and museums — that answer
    /// is the same next week. Re-billing 6 searches every 2 hours for it was pure waste.
    private static let longLivedStore = DiskCache<[DetailedPlace]>(name: "nearby-longlived", ttl: 7 * 24 * 3600)

    static func places(forKey key: String, longLived: Bool) async -> [DetailedPlace]? {
        await (longLived ? longLivedStore : store).value(forKey: key)
    }

    static func store(_ places: [DetailedPlace], forKey key: String, longLived: Bool) async {
        await (longLived ? longLivedStore : store).store(places, forKey: key)
    }

    /// Coordinate rounded to ~1km: the search radius already spans multiple km, so finer
    /// precision would only fragment the cache and cause redundant billed calls.
    static func key(
        includedTypes: [String],
        coordinate: CLLocationCoordinate2D,
        radius: Double,
        primaryTypesOnly: Bool
    ) -> String {
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lng = (coordinate.longitude * 100).rounded() / 100
        return "\(includedTypes.joined(separator: ","))|\(lat)|\(lng)|\(Int(radius))|\(primaryTypesOnly)"
    }
}
