import CoreLocation
import Foundation
import MapKit

/// A single route alternative, unified across MapKit (drive/walk) and Google Routes (transit/bike),
/// so the directions UI can present and draw them the same way.
struct RouteOption: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let travelTime: TimeInterval
    let distanceMeters: Double
    let summary: String
    let transitSteps: [TransitStep]

    var polyline: MKPolyline {
        MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    var boundingMapRect: MKMapRect {
        polyline.boundingMapRect
    }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = travelTime >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(travelTime, 60)) ?? "—"
    }

    var formattedDistance: String {
        Measurement(value: distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// A transit leg (a train/bus ride) surfaced from Google Routes transit details.
struct TransitStep: Identifiable {
    let id = UUID()
    let lineName: String
    let lineShortName: String?
    let vehicle: String
    let departureStop: String
    let arrivalStop: String
    let numStops: Int?
    let headsign: String?
    let color: String?

    var displayLine: String {
        lineShortName ?? lineName
    }
}

extension MKRoute {
    var coordinates: [CLLocationCoordinate2D] {
        let pointCount = polyline.pointCount
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: pointCount
        )
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
