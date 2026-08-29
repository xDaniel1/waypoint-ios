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
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: arrival)
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
    /// Google Routes' raw maneuver enum (e.g. "TURN_LEFT", "ROUNDABOUT_RIGHT"), when the step
    /// came from Google. Real per-lane guidance isn't something the public Routes API exposes
    /// at all — that's a Navigation SDK feature — so this only drives which turn arrow to show,
    /// not which lane to be in.
    var maneuver: String?

    var formattedDistance: String {
        Measurement(value: distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// SF Symbol matching the maneuver type, falling back to a plain straight arrow for
    /// anything unrecognized (including MapKit-sourced steps, which have no maneuver at all).
    var maneuverIcon: String {
        switch maneuver {
        case "TURN_SLIGHT_LEFT", "TURN_LEFT", "TURN_SHARP_LEFT", "RAMP_LEFT", "FORK_LEFT":
            "arrow.turn.up.left"
        case "TURN_SLIGHT_RIGHT", "TURN_RIGHT", "TURN_SHARP_RIGHT", "RAMP_RIGHT", "FORK_RIGHT":
            "arrow.turn.up.right"
        case "UTURN_LEFT":
            "arrow.uturn.left"
        case "UTURN_RIGHT":
            "arrow.uturn.right"
        case "ROUNDABOUT_LEFT", "ROUNDABOUT_RIGHT":
            "arrow.triangle.2.circlepath"
        case "MERGE":
            "arrow.triangle.merge"
        case "FERRY", "FERRY_TRAIN":
            "ferry.fill"
        default:
            "arrow.up"
        }
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
    var arrivalISO: String? = nil

    var displayLine: String {
        lineShortName ?? lineName
    }

    var isSubway: Bool {
        vehicle.uppercased().contains("SUBWAY") || vehicle.uppercased().contains("METRO")
            || vehicle.uppercased().contains("RAIL") || vehicle.uppercased().contains("TRAIN")
    }

    /// Real clock times from Google's transit stop details, locale-formatted — nil (not a
    /// fabricated placeholder) when Google didn't return one for this leg.
    var formattedDepartureTime: String? { Self.formattedClockTime(departureISO) }
    var formattedArrivalTime: String? { Self.formattedClockTime(arrivalISO) }

    private static func formattedClockTime(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    var vehicleSymbol: String {
        switch vehicle.uppercased() {
        case let v where v.contains("BUS"): "bus.fill"
        case let v where v.contains("FERRY") || v.contains("BOAT"): "ferry.fill"
        default: "tram.fill"
        }
    }

    /// The colour this ride draws and badges in — the MTA's own published colour for subway
    /// lines, since Google's transit colour data doesn't reliably match what the MTA actually
    /// brands each line (the J isn't always the right brown coming back from Google). Buses and
    /// other agencies fall back to whatever Google supplied.
    @MainActor
    var tintColor: Color {
        if isSubway, let official = MTASubwayLines.officialColor(forLine: displayLine) {
            return official
        }
        return Color(hex: color) ?? (isSubway ? .blue : .orange)
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

extension RouteOption {
    /// Minutes of the first walking leg, when the route starts with one.
    var firstWalkMinutes: Int? {
        for leg in transitLegs {
            if case .walk(let minutes) = leg { return minutes }
        }
        return nil
    }

    /// Minutes until the first ride departs, from the transit response's own departure time.
    var minutesUntilDeparture: Int? {
        guard let iso = transitSteps.first?.departureISO,
              let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return max(0, Int(date.timeIntervalSinceNow / 60))
    }
}

extension RouteOption {
    /// The colour this route draws in. Transit uses the operator's own line colour when the
    /// response carried one — Apple draws the J in its gold, the G in its green — and everything
    /// else falls back to the standard route blue.
    @MainActor
    var routeTint: Color {
        guard let step = transitSteps.first else { return .blue }
        return step.tintColor
    }
}
