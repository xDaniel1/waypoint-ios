import CoreLocation
import Foundation

struct FavoritePlace: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
