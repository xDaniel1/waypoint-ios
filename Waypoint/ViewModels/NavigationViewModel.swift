import CoreLocation
import MapKit
import Observation

/// Drives in-app turn-by-turn navigation: follow-camera, live ETA countdown,
/// current maneuver banner, and step advancement as the user reaches each turn.
///
/// This is NOT spoken voice guidance — that's an Apple-private system feature.
@Observable
@MainActor
final class NavigationViewModel {
    private(set) var route: RouteOption?
    private(set) var destinationName: String = ""
    private(set) var currentStepIndex: Int = 0
    private(set) var remainingTime: TimeInterval = 0
    private(set) var remainingDistance: Double = 0
    private(set) var progressIndex: Int = 0

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

    func start(route: RouteOption, destinationName: String) {
        self.route = route
        self.destinationName = destinationName
        currentStepIndex = 0
        progressIndex = 0
        remainingTime = route.travelTime
        remainingDistance = route.distanceMeters
    }

    func end() {
        route = nil
        destinationName = ""
        currentStepIndex = 0
        progressIndex = 0
        remainingTime = 0
        remainingDistance = 0
    }

    /// Updates progress from a new location fix — advances to the next step when close enough
    /// to that step's start point, and shortens the ETA linearly based on progress along the polyline.
    func update(with location: CLLocation) {
        guard let route else { return }
        // Advance the step index when we're within ~40m of the *next* step's start.
        if route.steps.indices.contains(currentStepIndex + 1),
           let nextStart = polylineCoord(forStep: currentStepIndex + 1, in: route),
           location.distance(from: CLLocation(latitude: nextStart.latitude, longitude: nextStart.longitude)) < 40 {
            currentStepIndex += 1
        }
        // Recompute remaining distance from the closest polyline point to the destination.
        let (idx, _) = closestPointIndex(to: location.coordinate, in: route.coordinates)
        progressIndex = idx
        let remaining = pathDistance(from: idx, in: route.coordinates)
        remainingDistance = remaining
        // Assume average travel speed = total distance / total time; scale ETA by remaining fraction.
        let totalDistance = route.distanceMeters
        if totalDistance > 0 {
            remainingTime = route.travelTime * (remaining / totalDistance)
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
