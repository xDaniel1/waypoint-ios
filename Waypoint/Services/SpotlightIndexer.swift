import CoreLocation
import CoreSpotlight
import Foundation
import MapKit
import OSLog

/// Publishes saved places to system search.
///
/// Apple Maps surfaces your favourites in Spotlight; without this, anything saved in Waypoint was
/// invisible the moment you left the app. Only favourites are indexed — recents are noisy, change
/// constantly, and would fill Spotlight with places you looked at once.
enum SpotlightIndexer {
    private static let domain = "com.danielguzman.waypoint.favorites"

    static func index(_ favorites: [FavoritePlace]) {
        let items = favorites.map { favorite -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = favorite.displayTitle
            attributes.contentDescription = favorite.subtitle
            // Lets Spotlight offer directions straight from the result.
            attributes.latitude = NSNumber(value: favorite.latitude)
            attributes.longitude = NSNumber(value: favorite.longitude)
            attributes.supportsNavigation = NSNumber(value: true)
            attributes.keywords = ["map", "place", "waypoint", favorite.title]

            return CSSearchableItem(
                uniqueIdentifier: favorite.id.uuidString,
                domainIdentifier: domain,
                attributeSet: attributes
            )
        }

        // Replacing the whole domain keeps Spotlight in step with deletions and renames, which
        // an incremental index would leave stale.
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
            if let error {
                Logger.places.error("Spotlight clear failed: \(error.localizedDescription)")
                return
            }
            guard !items.isEmpty else { return }
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error {
                    Logger.places.error("Spotlight index failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
