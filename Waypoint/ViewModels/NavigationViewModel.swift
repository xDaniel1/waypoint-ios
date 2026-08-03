import CoreLocation
import MapKit
import Observation

/// Drives in-app turn-by-turn navigation: follow-camera, live ETA countdown,
/// current maneuver banner, step advancement, spoken announcements, and automatic
/// rerouting when the driver drifts off the calculated path.
@Observable
@MainActor
final class NavigationViewModel {
    private(set) var route: RouteOption?
    private(set) var destinationName: String = ""
    private(set) var destinationCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()
    private(set) var currentStepIndex: Int = 0
    private(set) var remainingTime: TimeInterval = 0
    private(set) var remainingDistance: Double = 0
    private(set) var progressIndex: Int = 0

    /// Fired with the exact phrase to speak. Formatting (distance, wording) lives here so the
    /// speech service stays a dumb "speak this string" wrapper.
    var onAnnouncement: ((String) -> Void)?
    /// Fired when the driver has drifted far enough from the route that it should be
    /// recalculated. This view model doesn't know how to compute a new route itself — that's
    /// Google Routes' job — so it just signals the need; the caller supplies the new route
    /// via `reroute(to:)`.
    var onOffRoute: (() -> Void)?

    private var announcedUpcomingForStep: Int?
    private var announcedImmediateForStep = -1
    private var hasAnnouncedArrival = false
    private var offRouteStreak = 0
    private var lastRerouteRequest: Date = .distantPast
    /// Two consecutive fixes further than this from the route (not one — GPS jitters near
    /// overpasses/parking lots) before we treat it as actually off-route.
    private let offRouteThreshold: CLLocationDistance = 45

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

    func start(route: RouteOption, destinationName: String, destinationCoordinate: CLLocationCoordinate2D) {
        self.route = route
        self.destinationName = destinationName
        self.destinationCoordinate = destinationCoordinate
        currentStepIndex = 0
        progressIndex = 0
        remainingTime = route.travelTime
        remainingDistance = route.distanceMeters
        announcedUpcomingForStep = nil
        announcedImmediateForStep = -1
        hasAnnouncedArrival = false
        offRouteStreak = 0
        lastRerouteRequest = .distantPast
        announceFirstStep(of: route)
    }

    func end() {
        route = nil
        destinationName = ""
        currentStepIndex = 0
        progressIndex = 0
        remainingTime = 0
        remainingDistance = 0
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
        onAnnouncement?("Rerouting")
        announceFirstStep(of: newRoute)
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
        let (idx, offRouteDistance) = closestPointIndex(to: location.coordinate, in: route.coordinates)
        progressIndex = idx
        let remaining = pathDistance(from: idx, in: route.coordinates)
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

    private func closestPointIndex(to point: CLLocationCoordinate2D, in coords: [CLLocationCoordinate2D])
        -> (index: Int, distance: CLLocationDistance)
    {
        var bestIndex = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        let target = CLLocation(latitude: point.latitude, longitude: point.longitude)
        for (i, c) in coords.enumerated() {
            let d = target.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }
        return (bestIndex, bestDist)
    }

    private func pathDistance(from startIndex: Int, in coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.indices.contains(startIndex) else { return 0 }
        var total: Double = 0
        for i in startIndex..<(coords.count - 1) {
            let a = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            let b = CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude)
            total += a.distance(from: b)
        }
        return total
    }
}
