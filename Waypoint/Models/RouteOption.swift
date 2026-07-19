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
    var steps: [RouteStep] = []
    var hasTraffic: Bool = false

    var polyline: MKPolyline {
        MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    var boundingMapRect: MKMapRect {
        polyline.boundingMapRect
    }

    /// Coordinate roughly at the middle of the route, for placing a time bubble on the map.
    var midCoordinate: CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        return coordinates[coordinates.count / 2]
    }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = travelTime >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(travelTime, 60)) ?? "—"
    }

    /// Short "12 min" form used on the map bubble.
    var shortDuration: String {
        let minutes = max(1, Int((travelTime / 60).rounded()))
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) hr" : "\(h) hr \(m)"
        }
        return "\(minutes) min"
    }

    var formattedDistance: String {
        Measurement(value: distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    var formattedETA: String {
        let arrival = Date().addingTimeInterval(travelTime)
        return arrival.formatted(date: .omitted, time: .shortened)
    }
}

struct RouteStep: Identifiable {
    let id = UUID()
    let instruction: String
    let distanceMeters: Double

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
