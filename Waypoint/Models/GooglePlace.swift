import CoreLocation
import Foundation

struct GooglePlace: Codable, Identifiable {
    let id: String
    let displayName: LocalizedText?
    let primaryTypeDisplayName: LocalizedText?
    let formattedAddress: String?
    let internationalPhoneNumber: String?
    let websiteUri: String?
    let rating: Double?
    let userRatingCount: Int?
    let businessStatus: String?
    let currentOpeningHours: OpeningHours?
    let location: LatLng?
    let photos: [Photo]?
    let reviews: [Review]?
    let editorialSummary: LocalizedText?
    let priceLevel: String?
    let googleMapsUri: String?
    let paymentOptions: PaymentOptions?
    let goodForChildren: Bool?
    let restroom: Bool?
    let outdoorSeating: Bool?
    let servesVegetarianFood: Bool?
    let takeout: Bool?
    let delivery: Bool?
    let dineIn: Bool?

    /// Google's descriptive blurb for the place (landmark, park, business), when available.
    var descriptionText: String? {
        editorialSummary?.text
    }

    /// "$$" style indicator shown next to the category, matching Apple Maps.
    var priceIndicator: String? {
        switch priceLevel {
        case "PRICE_LEVEL_INEXPENSIVE": "$"
        case "PRICE_LEVEL_MODERATE": "$$"
        case "PRICE_LEVEL_EXPENSIVE": "$$$"
        case "PRICE_LEVEL_VERY_EXPENSIVE": "$$$$"
        default: nil
        }
    }

    /// The amenity list Apple shows under "Good to Know" — only truths, never guesses.
    var goodToKnow: [(symbol: String, label: String)] {
        var items: [(String, String)] = []
        if paymentOptions?.acceptsNfc == true { items.append(("wave.3.right.circle", "Accepts Contactless Payments")) }
        if paymentOptions?.acceptsCreditCards == true { items.append(("creditcard", "Accepts Credit Cards")) }
        if paymentOptions?.acceptsDebitCards == true { items.append(("creditcard.fill", "Accepts Debit Cards")) }
        if goodForChildren == true { items.append(("figure.and.child.holdinghands", "Good for Kids")) }
        if outdoorSeating == true { items.append(("sun.max", "Outdoor Seating")) }
        if servesVegetarianFood == true { items.append(("leaf", "Serves Vegetarian Food")) }
        if takeout == true { items.append(("bag", "Takeout")) }
        if delivery == true { items.append(("shippingbox", "Delivery")) }
        if dineIn == true { items.append(("fork.knife", "Dine In")) }
        if restroom == true { items.append(("figure.dress.line.vertical.figure", "Restroom")) }
        return items
    }

    struct PaymentOptions: Codable {
        let acceptsCreditCards: Bool?
        let acceptsDebitCards: Bool?
        let acceptsCashOnly: Bool?
        let acceptsNfc: Bool?
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        return CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    struct LatLng: Codable {
        let latitude: Double
        let longitude: Double
    }

    struct LocalizedText: Codable {
        let text: String
        let languageCode: String?
    }

    struct OpeningHours: Codable {
        let openNow: Bool?
        let weekdayDescriptions: [String]?
    }

    struct Photo: Codable, Identifiable {
        var id: String { name }
        let name: String
        let widthPx: Int?
        let heightPx: Int?
    }

    struct Review: Codable, Identifiable {
        var id: String { name }
        let name: String
        let relativePublishTimeDescription: String?
        let rating: Double?
        let text: LocalizedText?
        let authorAttribution: AuthorAttribution?

        struct AuthorAttribution: Codable {
            let displayName: String?
            let photoUri: String?
        }
    }
}
