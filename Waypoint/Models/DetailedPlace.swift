import CoreLocation
import Foundation
import MapKit

struct DetailedPlace: Codable, Identifiable {
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
        let periods: [Period]?

        struct Period: Codable {
            let open: Point?
            let close: Point?

            struct Point: Codable {
                /// 0 = Sunday, matching Google's numbering.
                let day: Int?
                let hour: Int?
                let minute: Int?
            }
        }

        /// "Open till 12 AM" / "Opens 5:30 PM" — the same at-a-glance line Apple Maps shows,
        /// derived from Google's real opening periods. Returns nil (rather than a vague "Open")
        /// when the periods aren't present, so the row just omits the line instead of guessing.
        var statusLine: (text: String, isOpen: Bool)? {
            guard let openNow else { return nil }
            guard let periods, !periods.isEmpty else {
                return (openNow ? "Open" : "Closed", openNow)
            }
            let calendar = Calendar.current
            let now = Date()
            let today = calendar.component(.weekday, from: now) - 1  // Calendar is 1-based, Google 0-based.

            if openNow {
                // The period covering now is the one that opened today, or one that opened
                // yesterday and runs past midnight.
                let candidates = periods.filter { $0.open?.day == today || $0.open?.day == (today + 6) % 7 }
                guard let close = candidates.compactMap(\.close).first,
                      let text = Self.format(hour: close.hour, minute: close.minute) else {
                    return ("Open", true)
                }
                return ("Open till \(text)", true)
            }

            // Closed: surface the next opening time today, else the earliest upcoming one.
            let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
            let laterToday = periods
                .compactMap(\.open)
                .filter { $0.day == today && (($0.hour ?? 0) * 60 + ($0.minute ?? 0)) > nowMinutes }
                .min { (($0.hour ?? 0) * 60 + ($0.minute ?? 0)) < (($1.hour ?? 0) * 60 + ($1.minute ?? 0)) }
            let next = laterToday ?? periods.compactMap(\.open).first
            guard let next, let text = Self.format(hour: next.hour, minute: next.minute) else {
                return ("Closed", false)
            }
            return ("Opens \(text)", false)
        }

        /// Locale-aware clock formatting. On the hour Apple drops the minutes entirely — "12 AM",
        /// not "12:00 AM" — so this does too, while still honouring 24-hour locales.
        private static func format(hour: Int?, minute: Int?) -> String? {
            guard let hour else { return nil }
            var components = DateComponents()
            components.hour = hour
            components.minute = minute ?? 0
            guard let date = Calendar.current.date(from: components) else { return nil }
            let full = date.formatted(date: .omitted, time: .shortened)
            guard (minute ?? 0) == 0 else { return full }
            // Strip a ":00" wherever the locale placed it, leaving any AM/PM suffix intact.
            return full.replacingOccurrences(of: ":00", with: "")
        }
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

extension DetailedPlace {
    init(mapItem: MKMapItem) {
        self.id = mapItem.name ?? UUID().uuidString
        self.displayName = LocalizedText(text: mapItem.name ?? "Unknown", languageCode: nil)
        let category = mapItem.pointOfInterestCategory?.rawValue.replacingOccurrences(of: "MKPOICategory", with: "") ?? "Place"
        self.primaryTypeDisplayName = LocalizedText(text: category, languageCode: nil)
        let placemark = mapItem.placemark
        let address = [placemark.subThoroughfare, placemark.thoroughfare, placemark.locality, placemark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        self.formattedAddress = address.isEmpty ? nil : address
        self.internationalPhoneNumber = mapItem.phoneNumber
        self.websiteUri = mapItem.url?.absoluteString
        self.rating = nil
        self.userRatingCount = nil
        self.businessStatus = nil
        self.currentOpeningHours = nil
        self.location = LatLng(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude)
        self.photos = nil
        self.reviews = nil
        self.editorialSummary = nil
        self.priceLevel = nil
        self.googleMapsUri = nil
        self.paymentOptions = nil
        self.goodForChildren = nil
        self.restroom = nil
        self.outdoorSeating = nil
        self.servesVegetarianFood = nil
        self.takeout = nil
        self.delivery = nil
        self.dineIn = nil
    }
}
