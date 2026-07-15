import CoreLocation
import MapKit

struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    let mapItem: MKMapItem

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    var title: String {
        mapItem.name ?? "Unknown Place"
    }

    var subtitle: String {
        let placemark = mapItem.placemark
        var components: [String] = []
        if let subThoroughfare = placemark.subThoroughfare, let thoroughfare = placemark.thoroughfare {
            components.append("\(subThoroughfare) \(thoroughfare)")
        } else if let thoroughfare = placemark.thoroughfare {
            components.append(thoroughfare)
        }
        if let locality = placemark.locality {
            components.append(locality)
        }
        return components.joined(separator: ", ")
    }

    var coordinate: CLLocationCoordinate2D {
        mapItem.placemark.coordinate
    }
}
