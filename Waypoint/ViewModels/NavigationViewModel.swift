import CoreLocation
import MapKit
import Observation
import SwiftUI

/// Something the driver flagged at their current location during a trip — a local note, not a
/// report to Apple/Google's crowdsourced traffic data (that's private infrastructure we don't
/// have access to). It doesn't route around its own coordinate either; Google's Routes API has
/// no avoid-this-exact-spot primitive. It's a marker for this trip, plus a nudge to recheck the
/// route in case Google's live-traffic model already knows about something better.
struct ReportedIncident: Identifiable {
    enum Kind: String, CaseIterable {
        case accident = "Accident"
        case hazard = "Hazard"
        case roadClosed = "Road Closed"
        case slowTraffic = "Slow Traffic"

        var symbol: String {
            switch self {
            case .accident: "car.side.rear.and.exclamationmark"
            case .hazard: "exclamationmark.triangle.fill"
            case .roadClosed: "road.lanes"
            case .slowTraffic: "clock.badge.exclamationmark.fill"
            }
        }

        /// Pin background color, matching the Apple/Waze convention of yellow for congestion
        /// vs. red for things that actually block the road.
        var tint: Color {
            switch self {
            case .accident: .red
            case .hazard: .orange
            case .roadClosed: .black
            case .slowTraffic: .yellow
            }
        }

        /// White reads fine on every tint except the yellow congestion pin, which needs a dark
        /// icon for contrast.
        var iconColor: Color {
            self == .slowTraffic ? .black : .white
        }
    }

    let id = UUID()
    let kind: Kind
    let coordinate: CLLocationCoordinate2D
}

/// Drives in-app turn-by-turn navigation: follow-camera, live ETA countdown,
/// current maneuver banner, step advancement, spoken announcements, and automatic
/// rerouting when the driver drifts off the calculated path.
@Observable
@MainActor
final class NavigationViewModel {
    private(set) var route: RouteOption?
    private(set) var destinationName: String = ""
    private(set) var destinationCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()
    /// Carried over so a reroute (drifting off path) recalculates through the same stops the
    /// trip started with — including ones already passed, since this doesn't track visit state.
    private(set) var intermediateStops: [CLLocationCoordinate2D] = []
    private(set) var reportedIncidents: [ReportedIncident] = []
    private(set) var currentStepIndex: Int = 0
    private(set) var remainingTime: TimeInterval = 0
    private(set) var remainingDistance: Double = 0
    private(set) var progressIndex: Int = 0

    /// Fired with the exact phrase to speak. Formatting (distance, wording) lives here so the
    /// speech service stays a dumb "speak this string" wrapper.
    var onAnnouncement: ((String) -> Void)?
    /// Fired when the driver has drifted far enough from the route that it should be
    /// recalculated, or a stop was added mid-trip via search-along-route. Either way this view
    /// model doesn't know how to compute a new route itself — that's Google Routes' job — so it
    /// just signals the need; the caller supplies the new route via `reroute(to:)`.
    var onOffRoute: (() -> Void)?
    var onStopAdded: (() -> Void)?
    var onIncidentReported: (() -> Void)?

    /// Projected copy of `route.coordinates`, built once when a route is set.
    ///
    /// Progress used to be measured by building two `CLLocation` objects per polyline point and
    /// calling `distance(from:)` — over the whole route, twice, on the main actor, on every GPS
    /// fix. A cross-Brooklyn transit route is thousands of points, so that was thousands of
    /// object allocations a second competing with the map for the main thread. `MKMapPoint` is a
    /// struct and its `distance(to:)` is plain arithmetic.
    private var mapPoints: [MKMapPoint] = []
    /// Metres from each point to the end of the route, so "how much is left" is a lookup rather
    /// than a fresh walk of the remaining polyline every fix.
    private var metresRemaining: [Double] = []

    private var announcedUpcomingForStep: Int?
    private var announcedImmediateForStep = -1
    private var hasAnnouncedArrival = false
    private var offRouteStreak = 0
    private var lastRerouteRequest: Date = .distantPast
    /// Two consecutive fixes further than this from the route (not one — GPS jitters near
    /// overpasses/parking lots) before we treat it as actually off-route.
    private let offRouteThreshold: CLLocationDistance = 45

    /// The route as the map should draw it right now: for a drive, the road ahead bright and
    /// the part behind dimmed; for a transit trip, each leg in its own line's colour, split at
    /// wherever you've got to.
    ///
    /// Recomputed only when progress actually moves to a new polyline point, not on every view
    /// evaluation — the arrays here get rebuilt, and the map's content closure runs far more
    /// often than the rider moves 25 metres.
    private(set) var drawableSegments: [DrawableRouteSegment] = []

    /// The portion of the route still ahead, drawn bright/thick like Apple Maps.
    var remainingCoordinates: [CLLocationCoordinate2D] {
        guard let route, route.coordinates.indices.contains(progressIndex) else { return route?.coordinates ?? [] }
        return Array(route.coordinates[progressIndex...])
    }

    /// The portion already driven, drawn dimmer/thinner behind the user.
    var traveledCoordinates: [CLLocationCoordinate2D] {
        guard let route, route.coordinates.indices.contains(progressIndex) else { return [] }
        return Array(route.coordinates[0...progressIndex])
    }

    var isActive: Bool { route != nil }
    var currentStep: RouteStep? {
        guard let route, route.steps.indices.contains(currentStepIndex) else { return nil }
        return route.steps[currentStepIndex]
    }
    var nextStep: RouteStep? {
        guard let route, route.steps.indices.contains(currentStepIndex + 1) else { return nil }
        return route.steps[currentStepIndex + 1]
    }
    /// The maneuver after the upcoming one — what Apple's "Then …" line refers to.
    var stepAfterNext: RouteStep? {
        guard let route, route.steps.indices.contains(currentStepIndex + 2) else { return nil }
        return route.steps[currentStepIndex + 2]
    }

    private(set) var currentLocation: CLLocation?
    
    /// Metres to the upcoming maneuver. The phone shows this formatted; CarPlay hands the raw
    /// measurement to `CPTravelEstimates` and lets the car format it in its own units.
    var distanceToNextManeuver: Double? {
        guard let route, route.steps.indices.contains(currentStepIndex + 1),
              let nextStart = polylineCoord(forStep: currentStepIndex + 1, in: route),
              let location = currentLocation else { return nil }
        return location.distance(from: CLLocation(latitude: nextStart.latitude, longitude: nextStart.longitude))
    }

    var formattedDistanceToNextStep: String? {
        guard let distance = distanceToNextManeuver, distance > 5 else { return nil }
        return Measurement(value: distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// The same 30m threshold `update(with:)` uses to announce arrival, exposed so CarPlay can
    /// finish its trip on the same condition the voice guidance calls it on.
    var hasArrived: Bool { isActive && remainingDistance < 30 }

    var formattedArrival: String {
        Date().addingTimeInterval(remainingTime)
            .formatted(date: .omitted, time: .shortened)
    }

    var formattedRemainingMinutes: String {
        let minutes = max(1, Int((remainingTime / 60).rounded()))
        return "\(minutes)"
    }

    var formattedRemainingDistance: String {
        Measurement(value: remainingDistance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    func start(
        route: RouteOption,
        destinationName: String,
        destinationCoordinate: CLLocationCoordinate2D,
        intermediateStops: [CLLocationCoordinate2D] = []
    ) {
        self.route = route
        self.destinationName = destinationName
        self.destinationCoordinate = destinationCoordinate
        self.intermediateStops = intermediateStops
        reportedIncidents = []
        currentStepIndex = 0
        progressIndex = 0
        remainingTime = route.travelTime
        remainingDistance = route.distanceMeters
        announcedUpcomingForStep = nil
        announcedImmediateForStep = -1
        hasAnnouncedArrival = false
        offRouteStreak = 0
        lastRerouteRequest = .distantPast
        cacheGeometry(of: route)
        rebuildDrawableSegments()
        announceFirstStep(of: route)
    }

    func end() {
        route = nil
        destinationName = ""
        intermediateStops = []
        reportedIncidents = []
        currentStepIndex = 0
        progressIndex = 0
        remainingTime = 0
        remainingDistance = 0
        mapPoints = []
        metresRemaining = []
        drawableSegments = []
    }

    /// Swaps in a freshly-calculated route after drifting off the original path. Unlike
    /// `start`, this doesn't touch destination bookkeeping — it's the same trip, just a new path
    /// to get there.
    func reroute(to newRoute: RouteOption) {
        route = newRoute
        currentStepIndex = 0
        progressIndex = 0
        remainingTime = newRoute.travelTime
        remainingDistance = newRoute.distanceMeters
        announcedUpcomingForStep = nil
        announcedImmediateForStep = -1
        cacheGeometry(of: newRoute)
        rebuildDrawableSegments()
        onAnnouncement?("Rerouting")
        announceFirstStep(of: newRoute)
    }

    /// Inserts a stop found via search-along-route and asks the caller to recompute the path
    /// through it. Appended to the end of `intermediateStops` — since results are only ever
    /// surfaced from points ahead of the driver on the remaining route, a new stop is always
    /// further along than any earlier ones.
    func addStop(_ coordinate: CLLocationCoordinate2D) {
        intermediateStops.append(coordinate)
        onStopAdded?()
    }

    /// Records a local marker for this trip and asks the caller to recheck the route — this
    /// doesn't feed Apple/Google's traffic data (private infrastructure) and doesn't route
    /// around the exact coordinate (Google's Routes API has no avoid-this-spot primitive), so
    /// it's honest to think of it as "note this, and see if there's a better path" rather than
    /// "avoid this road."
    func reportIncident(_ kind: ReportedIncident.Kind, at coordinate: CLLocationCoordinate2D) {
        reportedIncidents.append(ReportedIncident(kind: kind, coordinate: coordinate))
        onIncidentReported?()
    }

    private func announceFirstStep(of route: RouteOption) {
        guard let first = route.steps.first else { return }
        announcedImmediateForStep = 0
        onAnnouncement?(first.instruction)
    }

    /// Updates progress from a new location fix — advances to the next step when close enough
    /// to that step's start point, shortens the ETA linearly based on progress along the polyline,
    /// speaks upcoming/immediate maneuvers, and flags when the driver has drifted off the route.
    func update(with location: CLLocation) {
        self.currentLocation = location
        guard let route else { return }
        if route.steps.indices.contains(currentStepIndex + 1),
           let nextStart = polylineCoord(forStep: currentStepIndex + 1, in: route) {
            let distanceToNext = location.distance(from: CLLocation(latitude: nextStart.latitude, longitude: nextStart.longitude))
            let nextStep = route.steps[currentStepIndex + 1]

            // Pre-announce the upcoming maneuver once it's within ~500ft, while still on the
            // current step — "In 500 feet, turn right onto..." — then again right as it starts.
            if distanceToNext < 150, announcedUpcomingForStep != currentStepIndex + 1 {
                announcedUpcomingForStep = currentStepIndex + 1
                let distanceText = Measurement(value: distanceToNext, unit: UnitLength.meters)
                    .formatted(.measurement(width: .wide, usage: .road))
                onAnnouncement?("In \(distanceText), \(nextStep.instruction)")
            }

            if distanceToNext < 40 {
                currentStepIndex += 1
                if announcedImmediateForStep != currentStepIndex {
                    announcedImmediateForStep = currentStepIndex
                    onAnnouncement?(route.steps[currentStepIndex].instruction)
                }
            }
        }

        // Recompute remaining distance from the closest polyline point to the destination, and
        // track how far off that closest point actually is — that distance IS the off-route
        // check, no separate calculation needed.
        let (idx, offRouteDistance) = closestPointIndex(to: location.coordinate)
        if idx != progressIndex {
            progressIndex = idx
            rebuildDrawableSegments()
        }
        let remaining = metresRemaining.indices.contains(idx) ? metresRemaining[idx] : 0
        remainingDistance = remaining
        let totalDistance = route.distanceMeters
        if totalDistance > 0 {
            remainingTime = route.travelTime * (remaining / totalDistance)
        }

        if remaining < 30, !hasAnnouncedArrival {
            hasAnnouncedArrival = true
            onAnnouncement?("You have arrived at \(destinationName.isEmpty ? "your destination" : destinationName)")
        }

        offRouteStreak = offRouteDistance > offRouteThreshold ? offRouteStreak + 1 : 0
        if offRouteStreak >= 2, Date().timeIntervalSince(lastRerouteRequest) > 15 {
            lastRerouteRequest = Date()
            offRouteStreak = 0
            onOffRoute?()
        }
    }

    private func polylineCoord(forStep index: Int, in route: RouteOption) -> CLLocationCoordinate2D? {
        // We don't have per-step start coords, so approximate: divide the polyline into
        // equally-spaced chunks per step. Good enough for turn detection at ≤40m.
        guard !route.steps.isEmpty, !route.coordinates.isEmpty, index >= 0 else { return nil }
        let per = max(1, route.coordinates.count / max(route.steps.count, 1))
        let i = min(route.coordinates.count - 1, index * per)
        return route.coordinates[i]
    }

    /// Projects the route once and precomputes the distance-to-end table.
    private func cacheGeometry(of route: RouteOption) {
        mapPoints = route.coordinates.map(MKMapPoint.init)
        metresRemaining = Array(repeating: 0, count: mapPoints.count)
        guard mapPoints.count > 1 else { return }
        for i in stride(from: mapPoints.count - 2, through: 0, by: -1) {
            metresRemaining[i] = metresRemaining[i + 1] + mapPoints[i].distance(to: mapPoints[i + 1])
        }
    }

    /// Nearest polyline point to the rider, plus how far off it they are — that distance *is*
    /// the off-route check.
    ///
    /// Searches a window around where they were last, since a trip moves forward along the line
    /// rather than teleporting, and only falls back to scanning the whole route when nothing in
    /// the window is close — which is exactly the case (fresh start, reroute, genuinely off
    /// path) where the full scan is worth paying for.
    private func closestPointIndex(to point: CLLocationCoordinate2D)
        -> (index: Int, distance: CLLocationDistance)
    {
        guard !mapPoints.isEmpty else { return (0, 0) }
        let target = MKMapPoint(point)

        func scan(_ range: Range<Int>) -> (index: Int, distance: CLLocationDistance) {
            var bestIndex = range.lowerBound
            var bestDistance = CLLocationDistance.greatestFiniteMagnitude
            for i in range {
                let d = target.distance(to: mapPoints[i])
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = i
                }
            }
            return (bestIndex, bestDistance)
        }

        let window = 200
        let lower = max(0, progressIndex - window / 4)
        let upper = min(mapPoints.count, progressIndex + window)
        let near = scan(lower..<upper)
        if near.distance <= offRouteThreshold * 2 { return near }
        return scan(0..<mapPoints.count)
    }

    /// Rebuilds what the map draws for the current progress. Drives are one blue line split in
    /// two; transit trips keep each leg's own colour so a transfer reads as a colour change.
    private func rebuildDrawableSegments() {
        guard let route else {
            drawableSegments = []
            return
        }

        guard !route.transitSegments.isEmpty else {
            let driveStyle = StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
            var pieces: [DrawableRouteSegment] = []
            let traveled = traveledCoordinates
            if traveled.count > 1 {
                pieces.append(.init(id: "traveled", coordinates: traveled, color: .blue, strokeStyle: driveStyle, isTraveled: true))
            }
            let remaining = remainingCoordinates
            if remaining.count > 1 {
                pieces.append(.init(id: "remaining", coordinates: remaining, color: .blue, strokeStyle: driveStyle, isTraveled: false))
            }
            drawableSegments = pieces
            return
        }

        var pieces: [DrawableRouteSegment] = []
        for (n, segment) in route.transitSegments.enumerated() {
            // `segment.coordinates` reaches one point back into the previous leg so the colours
            // meet cleanly, so the offset between a route-wide index and a local one is 1 for
            // every leg but the first.
            let offset = segment.range.lowerBound > 0 ? 1 : 0
            let split = progressIndex - segment.range.lowerBound + offset
            let colour = segment.color
            let style = segment.strokeStyle

            if split <= 0 {
                pieces.append(.init(id: "\(n)-ahead", coordinates: segment.coordinates, color: colour, strokeStyle: style, isTraveled: false))
            } else if split >= segment.coordinates.count - 1 {
                pieces.append(.init(id: "\(n)-done", coordinates: segment.coordinates, color: colour, strokeStyle: style, isTraveled: true))
            } else {
                pieces.append(.init(id: "\(n)-done", coordinates: Array(segment.coordinates[0...split]), color: colour, strokeStyle: style, isTraveled: true))
                pieces.append(.init(id: "\(n)-ahead", coordinates: Array(segment.coordinates[split...]), color: colour, strokeStyle: style, isTraveled: false))
            }
        }
        drawableSegments = pieces
    }
}

/// One stroke the map draws for the active trip.
struct DrawableRouteSegment: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
    let strokeStyle: StrokeStyle
    /// Already behind the rider, so it renders dimmed.
    let isTraveled: Bool
}
