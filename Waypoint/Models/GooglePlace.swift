import Foundation

struct GooglePlace: Codable {
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
    let photos: [Photo]?
    let reviews: [Review]?

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
