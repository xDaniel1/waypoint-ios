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
    /// Where each step's maneuver begins, as an index into `mapPoints`. Built from the steps'
    /// own start coordinates where the provider gave them.
    private var stepIndices: [Int] = []
    /// The matched point the drawn line was last split at, so the split can be refreshed when
    /// the rider has actually moved rather than on every fix.
    private var lastDrawPoint: MKMapPoint?
    /// Every station the trip's rides call at, pinned to its point on the route, so "next stop"
    /// and "how many left" are comparisons against progress rather than searches.
    private var rideStops: [RideStop] = []

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

    /// The fix pulled onto the route — what the puck should be drawn at while a trip is running.
    ///
    /// A raw GPS fix sits a few metres to the side of the road or the track, and it wanders
    /// between fixes even when you're going straight, which is what makes the dot look like it's
    /// stumbling along beside the line instead of down it. Every navigation app matches the fix
    /// to the path it already knows you're on.
    ///
    /// This is only set while the fix's own error bar actually reaches the route (see
    /// `matchTolerance`). Drift wider than that means the phone is saying you're somewhere else,
    /// and drawing you on the line anyway would be inventing a position — so the puck goes back
    /// to the raw fix and the map shows the truth, which is also exactly when a reroute is
    /// about to fire.
    private(set) var matchedCoordinate: CLLocationCoordinate2D?

    /// Which way the route runs where you are, for pointing the puck along the road rather than
    /// wherever the phone happens to be held. Only set while you're moving fast enough for the
    /// direction of travel to be the thing you're facing.
    private(set) var matchedCourse: CLLocationDirection?

    /// Metres to the upcoming maneuver, measured *along the route* rather than as the crow
    /// flies — the two differ by most of a block on anything but a straight road, and it's the
    /// along-the-road figure that belongs on the banner.
    private(set) var distanceToNextManeuver: Double?

    /// The leg of a transit trip the rider is on right now.
    var currentTransitSegment: TransitSegment? {
        route?.transitSegments.first { $0.range.contains(progressIndex) }
    }

    /// The train or bus you're actually on, or nil while you're walking.
    var currentRide: TransitStep? {
        guard let route, let index = currentTransitSegment?.rideIndex,
              route.transitSteps.indices.contains(index) else { return nil }
        return route.transitSteps[index]
    }

    /// The next ride ahead of you — what the walk you're on is a walk *to*. nil once the last
    /// ride is behind you and all that's left is the walk to the door.
    var upcomingRide: TransitStep? {
        guard let route else { return nil }
        let next = route.transitSegments
            .first { $0.range.lowerBound > progressIndex && $0.rideIndex != nil }
        guard let index = next?.rideIndex, route.transitSteps.indices.contains(index) else { return nil }
        return route.transitSteps[index]
    }

    /// The station the train is pulling into next, from the MTA's own stop sequence for the
    /// line. nil off the subway, or for a ride whose ends the bundled data couldn't match — an
    /// unnamed next stop is better than a guessed one.
    var nextStopName: String? {
        rideStops.first { $0.index > progressIndex }?.name
    }

    /// Stops between here and where you get off, the one you're pulling into included.
    var stopsUntilExit: Int? {
        guard currentRide != nil else { return nil }
        let ahead = rideStops.filter { $0.index > progressIndex }
        return ahead.isEmpty ? nil : ahead.count
    }

    /// A station on one of the trip's rides, pinned to where it falls along the route.
    private struct RideStop {
        let name: String
        let index: Int
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
        distanceToNextManeuver = nil
        matchedCoordinate = nil
        matchedCourse = nil
        lastDrawPoint = nil
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
        stepIndices = []
        rideStops = []
        lastDrawPoint = nil
        matchedCoordinate = nil
        matchedCourse = nil
        distanceToNextManeuver = nil
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
        matchedCoordinate = nil
        matchedCourse = nil
        lastDrawPoint = nil
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

    /// Updates progress from a new location fix: matches the fix onto the route, advances the
    /// maneuver when you actually reach it, shortens the ETA, speaks what's coming, and flags a
    /// drift wide enough to need a new route.
    func update(with location: CLLocation) {
        self.currentLocation = location
        guard let route, let match = matchToRoute(location.coordinate) else { return }

        let movedToNewPoint = match.index != progressIndex
        progressIndex = match.index
        remainingDistance = match.metresRemaining
        remainingTime = estimatedRemainingTime(metresLeft: match.metresRemaining, of: route)

        // Pull the puck onto the line, but only while the fix itself says the line is within
        // reach — see `matchedCoordinate`.
        if match.offRouteDistance <= matchTolerance(for: location) {
            matchedCoordinate = match.point.coordinate
            // Below walking pace the direction of travel is noise; the compass is the better
            // answer for which way someone standing still is facing.
            matchedCourse = location.speed > 1.5 ? match.course : nil
        } else {
            matchedCoordinate = nil
            matchedCourse = nil
        }

        // Redraw when progress reached a new polyline point, or when the exact cut point has
        // moved far enough to see. Rebuilding copies the route's coordinates, so it isn't
        // something to do on every fix just to move the split a metre.
        let movedFarEnough = lastDrawPoint.map { $0.distance(to: match.point) > 20 } ?? true
        if movedToNewPoint || movedFarEnough {
            lastDrawPoint = match.point
            rebuildDrawableSegments()
        }

        advanceSteps(of: route, metresLeft: match.metresRemaining)

        if match.metresRemaining < 30, !hasAnnouncedArrival {
            hasAnnouncedArrival = true
            onAnnouncement?("You have arrived at \(destinationName.isEmpty ? "your destination" : destinationName)")
        }

        // The perpendicular distance to the route *is* the off-route check. It used to be the
        // distance to the nearest polyline vertex, which on a long straight stretch reads as
        // hundreds of metres off-route from the middle of a lane you're driving perfectly.
        offRouteStreak = match.offRouteDistance > offRouteThreshold ? offRouteStreak + 1 : 0
        if offRouteStreak >= 2, Date().timeIntervalSince(lastRerouteRequest) > 15 {
            lastRerouteRequest = Date()
            offRouteStreak = 0
            onOffRoute?()
        }
    }

    /// Moves the banner to the next maneuver when you reach it, and speaks the pre-announcement
    /// on the way in. Distances here are along the road, not straight-line.
    private func advanceSteps(of route: RouteOption, metresLeft: Double) {
        guard route.steps.indices.contains(currentStepIndex + 1) else {
            distanceToNextManeuver = nil
            return
        }
        let nextIndex = currentStepIndex + 1
        guard let toNext = distanceAlongRoute(from: metresLeft, toStepAt: nextIndex) else {
            distanceToNextManeuver = nil
            return
        }
        distanceToNextManeuver = toNext

        // "In 500 feet, turn right onto…" while still on the current step.
        if toNext < 150, announcedUpcomingForStep != nextIndex {
            announcedUpcomingForStep = nextIndex
            let distanceText = Measurement(value: toNext, unit: UnitLength.meters)
                .formatted(.measurement(width: .wide, usage: .road))
            onAnnouncement?("In \(distanceText), \(route.steps[nextIndex].instruction)")
        }

        // Reaching the maneuver point clamps the along-route distance to zero, so passing it
        // between fixes still advances rather than skipping the step.
        if toNext < 15 {
            currentStepIndex = nextIndex
            if announcedImmediateForStep != currentStepIndex {
                announcedImmediateForStep = currentStepIndex
                onAnnouncement?(route.steps[currentStepIndex].instruction)
            }
            distanceToNextManeuver = distanceAlongRoute(from: metresLeft, toStepAt: currentStepIndex + 1)
        }
    }

    /// Metres along the route from the rider's matched position to where a step begins.
    private func distanceAlongRoute(from metresLeft: Double, toStepAt index: Int) -> Double? {
        guard stepIndices.indices.contains(index) else { return nil }
        let point = stepIndices[index]
        guard metresRemaining.indices.contains(point) else { return nil }
        return max(0, metresLeft - metresRemaining[point])
    }

    /// How long is left. A drive scales its own estimate by how much road is left, which is fair
    /// when the whole trip moves at road speed. A transit trip doesn't work that way — see
    /// `TransitSegment.seconds` — so it adds up the legs instead when the provider gave their
    /// durations.
    private func estimatedRemainingTime(metresLeft: Double, of route: RouteOption) -> TimeInterval {
        if let byLeg = transitRemainingTime(metresLeft: metresLeft, of: route) { return byLeg }
        guard route.distanceMeters > 0 else { return remainingTime }
        return route.travelTime * (metresLeft / route.distanceMeters)
    }

    /// The legs still ahead at their own durations, plus whatever's left of the one you're on.
    /// nil when this isn't a transit trip or the provider didn't time every leg — a partial sum
    /// would read as a confident number built out of a hole.
    private func transitRemainingTime(metresLeft: Double, of route: RouteOption) -> TimeInterval? {
        let segments = route.transitSegments
        guard !segments.isEmpty, segments.allSatisfy({ $0.seconds != nil }) else { return nil }

        var total: TimeInterval = 0
        for segment in segments {
            guard let seconds = segment.seconds else { return nil }
            let first = segment.range.lowerBound
            let last = max(first, segment.range.upperBound - 1)
            guard metresRemaining.indices.contains(first), metresRemaining.indices.contains(last) else {
                return nil
            }
            let atStart = metresRemaining[first]
            let atEnd = metresRemaining[last]
            if metresLeft <= atEnd { continue }          // leg is entirely behind you
            if metresLeft >= atStart { total += seconds; continue }  // not started yet
            let span = atStart - atEnd
            total += span > 0 ? seconds * ((metresLeft - atEnd) / span) : seconds
        }
        return total
    }

    /// How far a fix may sit from the route before matching it to the line stops being a
    /// correction and starts being an invention.
    ///
    /// A fix carries its own error radius. When the route falls inside that radius, the route is
    /// the better answer than the centre of the circle — that's the whole idea. The floor covers
    /// a phone claiming better accuracy than GPS between tall buildings actually delivers, and
    /// the ceiling stops a 200m subway-platform fix from snapping onto a line it has no real
    /// evidence of being near.
    private func matchTolerance(for location: CLLocation) -> CLLocationDistance {
        guard location.horizontalAccuracy >= 0 else { return 12 }
        return max(12, min(location.horizontalAccuracy, 60))
    }

    /// Projects the route once and precomputes the distance-to-end table.
    private func cacheGeometry(of route: RouteOption) {
        mapPoints = route.coordinates.map(MKMapPoint.init)
        metresRemaining = Array(repeating: 0, count: mapPoints.count)
        guard mapPoints.count > 1 else {
            stepIndices = []
            return
        }
        for i in stride(from: mapPoints.count - 2, through: 0, by: -1) {
            metresRemaining[i] = metresRemaining[i + 1] + mapPoints[i].distance(to: mapPoints[i + 1])
        }
        cacheStepIndices(of: route)
        cacheRideStops(of: route)
    }

    /// Pins each station of each ride to its point on the route.
    ///
    /// Google's transit response only names where you get on and where you get off — the stops
    /// in between come from the bundled MTA stop sequences, the same data the itinerary sheet
    /// lists. Rides the bundle can't resolve (a bus line it doesn't cover, an unfamiliar station
    /// spelling) contribute nothing rather than a guess, which is why `nextStopName` is optional
    /// rather than falling back to something plausible-sounding.
    private func cacheRideStops(of route: RouteOption) {
        rideStops = []
        for segment in route.transitSegments {
            guard let rideIndex = segment.rideIndex,
                  route.transitSteps.indices.contains(rideIndex) else { continue }
            let ride = route.transitSteps[rideIndex]
            guard let stops = MTASubwayData.intermediateStops(
                line: ride.displayLine,
                from: ride.departureStop,
                to: ride.arrivalStop
            ) else { continue }

            for stop in stops {
                guard let index = nearestIndex(to: stop.stop.coordinate, within: segment.range) else { continue }
                rideStops.append(RideStop(name: stop.stop.name, index: index))
            }
        }
        rideStops.sort { $0.index < $1.index }
    }

    /// Nearest route point to a coordinate, searched only inside one leg — a station name can
    /// repeat along a line, and the transfer point of an out-and-back trip is genuinely near
    /// two different parts of the route.
    private func nearestIndex(to coordinate: CLLocationCoordinate2D, within range: Range<Int>) -> Int? {
        let clamped = max(0, range.lowerBound)..<min(mapPoints.count, range.upperBound)
        guard !clamped.isEmpty else { return nil }
        let target = MKMapPoint(coordinate)
        var best = clamped.lowerBound
        var bestDistance = Double.greatestFiniteMagnitude
        for i in clamped {
            let d = target.distance(to: mapPoints[i])
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        // A station that isn't actually near this leg's geometry isn't on this leg.
        return bestDistance < 400 ? best : nil
    }

    /// Pins each maneuver to the point on the route where it actually happens.
    ///
    /// Steps arrive in order, so the search for one starts where the last one landed. Providers
    /// that don't hand back per-step geometry fall back to the proportional guess this whole
    /// thing used to do for every step — wrong, but no more wrong than it already was, and only
    /// for those steps.
    private func cacheStepIndices(of route: RouteOption) {
        stepIndices = []
        guard !route.steps.isEmpty else { return }
        stepIndices.reserveCapacity(route.steps.count)

        var searchFrom = 0
        for (n, step) in route.steps.enumerated() {
            guard let start = step.startCoordinate else {
                let per = max(1, mapPoints.count / route.steps.count)
                stepIndices.append(min(mapPoints.count - 1, n * per))
                continue
            }
            let target = MKMapPoint(start)
            var best = searchFrom
            var bestDistance = Double.greatestFiniteMagnitude
            for i in searchFrom..<mapPoints.count {
                let d = target.distance(to: mapPoints[i])
                if d < bestDistance {
                    bestDistance = d
                    best = i
                }
            }
            stepIndices.append(best)
            searchFrom = best
        }
    }

    /// One fix matched onto the route.
    private struct RouteMatch {
        /// Index of the polyline point the matched position sits on or just after.
        let index: Int
        /// The position itself — a point on the route, not one of its vertices.
        let point: MKMapPoint
        /// Perpendicular metres from the fix to the route.
        let offRouteDistance: CLLocationDistance
        /// Metres of route left from the matched position.
        let metresRemaining: Double
        /// Compass bearing the route runs in here.
        let course: CLLocationDirection
    }

    /// Matches a fix to the closest point on the route — on the *segments*, not just at the
    /// vertices.
    ///
    /// The vertex version of this was wrong in a way that mattered. Polyline points are dense
    /// around turns and sparse on a straight, so half a mile of highway can be two points; a car
    /// squarely in the middle of it reads as a quarter mile from the nearest one. That inflated
    /// distance was the off-route check (spurious "rerouting" on empty highway), the remaining
    /// distance (an ETA that only moved in chunks) and the puck's position all at once.
    ///
    /// Searches a window around where the rider was last, since a trip moves forward along the
    /// line rather than teleporting, and falls back to the whole route only when nothing in the
    /// window is close — a fresh start, a reroute, or genuinely off the path.
    private func matchToRoute(_ coordinate: CLLocationCoordinate2D) -> RouteMatch? {
        guard mapPoints.count > 1 else { return nil }
        let target = MKMapPoint(coordinate)

        func scan(_ range: Range<Int>) -> RouteMatch? {
            guard !range.isEmpty else { return nil }
            var best: RouteMatch?
            for i in range {
                let a = mapPoints[i]
                let b = mapPoints[i + 1]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let lengthSquared = dx * dx + dy * dy
                var t = 0.0
                if lengthSquared > 0 {
                    t = ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared
                    t = min(max(t, 0), 1)
                }
                let projected = MKMapPoint(x: a.x + dx * t, y: a.y + dy * t)
                let offRoute = target.distance(to: projected)
                if let current = best, offRoute >= current.offRouteDistance { continue }
                let segmentLength = a.distance(to: b)
                best = RouteMatch(
                    // Landing on the far end of a segment means that vertex is reached, not
                    // still ahead — otherwise standing exactly on a point reports the one
                    // behind it, and everything keyed off progress (which transit leg you're
                    // on, what's already drawn as travelled) lags a point behind you.
                    index: t >= 1 ? min(i + 1, mapPoints.count - 1) : i,
                    point: projected,
                    offRouteDistance: offRoute,
                    metresRemaining: max(0, metresRemaining[i] - segmentLength * t),
                    course: Self.bearing(from: a.coordinate, to: b.coordinate)
                )
            }
            return best
        }

        let segments = mapPoints.count - 1
        let lower = max(0, progressIndex - 50)
        let upper = min(segments, progressIndex + 200)
        if let near = scan(lower..<upper), near.offRouteDistance <= offRouteThreshold * 2 {
            return near
        }
        return scan(0..<segments)
    }

    /// Compass bearing from one coordinate to another, for pointing the puck along the route.
    private static func bearing(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
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
            var traveled = traveledCoordinates
            var remaining = remainingCoordinates
            // Cut the line where the car actually is rather than at the nearest polyline point.
            // On a highway those sit a quarter mile apart, so the bright "road ahead" used to
            // start well behind or ahead of the puck.
            if let cut = matchedCoordinate, !remaining.isEmpty {
                traveled.append(cut)
                remaining[0] = cut
            }
            if traveled.count > 1 {
                pieces.append(.init(id: "traveled", coordinates: traveled, color: .blue, strokeStyle: driveStyle, isTraveled: true))
            }
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
