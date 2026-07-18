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
