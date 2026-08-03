import CoreLocation
import Foundation
import MapKit
import SwiftUI

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
    /// Slow/jammed stretches of this route, for drawing colored segments on the map instead of
    /// just the whole-route `hasTraffic` badge. Empty for transit/walk/bike — Google only
    /// returns this for traffic-aware driving routes.
    var congestionSegments: [CongestionSegment] = []
    /// Ordered walk/transit legs for the transit card's icon sequence.
    var transitLegs: [DirectionsLeg] = []
    /// e.g. "$3.00"
    var fare: String?
    /// e.g. "Bus departs in 6 min" or "Leave by 7:49 PM"
    var departureText: String?
    /// Named stops along the selected transit ride, for drawing on the map.
    var transitStops: [NamedStop] = []

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

/// A stretch of a route Google's live traffic data marks as slower than free-flow — drawn as a
/// colored overlay on top of the base route line, the way Apple/Google Maps color congested
/// roads. Not a discrete incident (accident, closure, construction): Google's Routes API only
/// exposes per-segment *speed*, not incident type/location, so that stays a real gap rather
/// than something faked here.
struct CongestionSegment: Identifiable {
    enum Severity {
        case slow, jam

        var color: Color {
            switch self {
            case .slow: .orange
            case .jam: .red
            }
        }
    }

    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let severity: Severity
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
    var departureISO: String? = nil

    var displayLine: String {
        lineShortName ?? lineName
    }

    var isSubway: Bool {
        vehicle.uppercased().contains("SUBWAY") || vehicle.uppercased().contains("METRO")
            || vehicle.uppercased().contains("RAIL") || vehicle.uppercased().contains("TRAIN")
    }

    var vehicleSymbol: String {
        switch vehicle.uppercased() {
        case let v where v.contains("BUS"): "bus.fill"
        case let v where v.contains("FERRY") || v.contains("BOAT"): "ferry.fill"
        default: "tram.fill"
        }
    }
}

/// One leg of a transit itinerary: either a walk of N minutes, or a transit ride.
enum DirectionsLeg: Identifiable {
    case walk(minutes: Int)
    case transit(TransitStep)

    var id: String {
        switch self {
        case .walk(let m): "walk-\(m)-\(UUID().uuidString.prefix(4))"
        case .transit(let s): "transit-\(s.id)"
        }
    }
}

struct NamedStop: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

/// A waypoint the driver added to a trip — "Add Stop" in the directions card — distinct from
/// `NamedStop`, which is a transit line's own stops.
struct RouteStop: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem

    var title: String { mapItem.name ?? "Stop" }
    var coordinate: CLLocationCoordinate2D { mapItem.placemark.coordinate }
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
