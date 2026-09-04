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
    /// Where each rider-added stop falls in `coordinates`, so the map can pin it on the line and
    /// navigation knows which arrival is a stop rather than the end of the trip. Empty for a trip
    /// with no stops.
    var stopIndices: [Int] = []
    /// Set when this route still runs through somewhere a problem has been reported, which only
    /// happens when every alternate does — see `AppleRoutesService.preferring(_:avoiding:)`.
    var passesReportedIncident: Bool = false
    /// The road this route is mostly made of, as MapKit named it — kept separately from `summary`
    /// so a multi-leg trip can build its own "via A and B" out of its legs' names.
    var roadName: String?
    /// The route broken into the individual legs you actually travel — each walk and each ride
    /// separately — so the map can draw a J ride in the J's brown and the A you transfer to in
    /// the A's blue, instead of painting the whole trip one colour. Empty for non-transit
    /// routes, and empty for transit routes where the provider didn't return per-step geometry;
    /// `MapScreen` falls back to a single `routeTint` line in that case.
    var transitSegments: [TransitSegment] = []

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
        let formatter = travelTime >= 3600 ? Formatters.hoursAndMinutes : Formatters.minutesOnly
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
        return Formatters.bareClockTime.string(from: Date().addingTimeInterval(travelTime))
    }
}

/// One leg of a transit trip as a drawable stretch of the map, in the colour of the service
/// you're on for that stretch.
///
/// Apple Maps colours a transit route per ride: the J's brown up to the transfer, the A's blue
/// after it, with the walk to and from the station in grey. Doing that needs the geometry split
/// the same way the itinerary is, which is why the Routes request asks for each step's own
/// polyline rather than just the whole-route one.
struct TransitSegment: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    /// Where this leg sits inside `RouteOption.coordinates`, so navigation progress (a single
    /// index along the whole route) can tell which part of this leg is already behind you.
    let range: Range<Int>
    let isWalk: Bool
    /// The bare service designation — "J", "A", "M14A-SBS" — or nil for a walk.
    let lineLabel: String?
    /// Whatever colour the provider supplied, used only for operators the MTA bundle doesn't
    /// cover. Subway lines always use the MTA's own published colour.
    let providerColor: String?
    let isSubway: Bool
    /// Which of `RouteOption.transitSteps` this leg is, so navigation can name the ride you're
    /// on right now. nil for a walk.
    var rideIndex: Int?
    /// How long the provider says this leg alone takes.
    ///
    /// A transit trip's remaining time can't be scaled off distance the way a drive's can: the
    /// 700m walk to the station is a tenth of the miles and half the minutes. With each leg's
    /// own duration, "12 min left" comes from the legs still ahead of you plus the leftover of
    /// the one you're on. nil when the provider didn't say, in which case navigation falls back
    /// to the distance-proportional estimate.
    var seconds: Double?

    /// Walking legs draw in the same grey Apple uses, so the coloured stretches read as "this
    /// is the part where you're on a train."
    @MainActor
    var color: Color {
        if isWalk { return Color(.systemGray) }
        if isSubway, let label = lineLabel, let official = MTASubwayLines.officialColor(forLine: label) {
            return official
        }
        return Color(hex: providerColor) ?? (isSubway ? .blue : .orange)
    }

    /// Apple dots the walking legs rather than drawing them solid.
    var strokeStyle: StrokeStyle {
        isWalk
            ? StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [1, 9])
            : StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
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
    /// Where along the route this maneuver actually starts, taken from the step's own polyline.
    ///
    /// Navigation used to guess this by cutting the route's coordinates into equal-sized chunks,
    /// one per step, which is wrong the moment steps differ in length — and they always do. A
    /// half-mile of highway and a 60ft merge got the same slice, so "In 500 feet, turn right"
    /// fired at the wrong place and the banner switched maneuvers early or late.
    ///
    /// nil for providers that don't return per-step geometry; navigation falls back to the old
    /// proportional estimate for those rather than pretending to a precision it doesn't have.
    var startCoordinate: CLLocationCoordinate2D?
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
        case "ARRIVE_STOP":
            "mappin.circle.fill"
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

    /// The bare service letter/number a rider actually calls the line — "L", not "L Line" or
    /// "Canarsie Local".
    ///
    /// Google's `nameShort` is usually already that, but it's optional, and when it's missing the
    /// only thing left is the full route name ("14 St-Canarsie Local"), which is what was ending
    /// up on the badges. So the name is checked against the MTA's real service designations and
    /// reduced to the bare token when one is in there; anything that isn't an MTA subway service
    /// (buses, other agencies) keeps whatever Google supplied rather than being mangled.
    var displayLine: String {
        let candidate = lineShortName ?? lineName
        if let service = Self.mtaService(in: candidate) { return service }
        return candidate
    }

    /// The MTA's own service designations. Hardcoding them is safe in a way a guess wouldn't be —
    /// this is the fixed, published set of NYC subway services, and it's the same set the bundled
    /// line geometry in `MTASubwayLines.json` is keyed by.
    private static let mtaServices: Set<String> = [
        "1", "2", "3", "4", "5", "6", "7", "6X", "7X",
        "A", "B", "C", "D", "E", "F", "FX", "G", "J", "L", "M", "N", "Q", "R", "W", "Z",
        "H", "FS", "GS", "SI",
    ]

    /// Pulls the service designation out of a line label, tolerating the shapes Google actually
    /// returns: "L", "L Line", "L Train", "MTA Subway L".
    private static func mtaService(in label: String) -> String? {
        let cleaned = label
            .replacingOccurrences(of: "MTA", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "Subway", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "Train", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "Line", with: " ", options: .caseInsensitive)
        let tokens = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // Only a label that reduces to exactly one token is a service designation. "14 St-Canarsie
        // Local" leaves several, and guessing one of those would put the wrong letter on the badge.
        guard tokens.count == 1, let token = tokens.first else { return nil }
        let upper = token.uppercased()
        return mtaServices.contains(upper) ? upper : nil
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
        guard let iso, let date = Formatters.iso8601.date(from: iso) else { return nil }
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
              let date = Formatters.iso8601.date(from: iso) else { return nil }
        return max(0, Int(date.timeIntervalSinceNow / 60))
    }
}

extension RouteOption {
    /// The colour this route draws in when it can't be drawn leg by leg. Transit uses the
    /// operator's own line colour when the response carried one — Apple draws the J in its gold,
    /// the G in its green — and everything else falls back to the standard route blue.
    ///
    /// Prefer `transitSegments` where it's non-empty: this only ever knows about the *first*
    /// ride, so a J-then-A trip drawn with it is brown the whole way.
    @MainActor
    var routeTint: Color {
        guard let step = transitSteps.first else { return .blue }
        return step.tintColor
    }

    /// The leg you're on at a given point along the route, by the same index navigation tracks
    /// progress with. Used to tint the banner and the remaining-line while riding.
    func transitSegment(at index: Int) -> TransitSegment? {
        transitSegments.first { $0.range.contains(index) } ?? transitSegments.last
    }
}
