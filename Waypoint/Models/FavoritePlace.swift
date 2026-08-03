import CoreLocation
import Foundation

struct FavoritePlace: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    /// User-chosen overrides, all nil until someone edits the favorite. Optional (rather than
    /// re-deriving a default at save time) so old-format decoded favorites — saved before this
    /// existed — just fall back to the same auto-derived look they always had.
    var customTitle: String? = nil
    var emoji: String? = nil
    var colorHex: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        guard let customTitle, !customTitle.isEmpty else { return title }
        return customTitle
    }
}
