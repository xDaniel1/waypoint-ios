import CoreLocation
import MapKit

/// Real MapKit-based routing — on-device `MKDirections`, free with no per-request billing, unlike
/// the Google Routes API this replaces. Two honest limitations worked around here rather than
/// faked: `MKDirections` has no native multi-waypoint request, so a route with stops is computed
/// as real chained point-to-point legs and concatenated, instead of one waypoint-aware request
/// (and loses route alternates once there's a stop, same simplification the old Google-backed
/// path used); and MapKit's public transit directions carry far less detail than Google's (no
/// line/vehicle/stop-level data), so transit routes here always have empty `transitSteps` rather
/// than fabricated ones.
@MainActor
struct AppleRoutesService {
    enum RouteError: Error {
        case noRoute
    }

    func computeRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: MKMapItem,
        stops: [MKMapItem] = [],
        transportType: MKDirectionsTransportType,
        avoidTolls: Bool = false,
        avoidHighways: Bool = false
    ) async throws -> [RouteOption] {
        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        let waypoints = [originItem] + stops + [destination]

        guard waypoints.count > 2 else {
            return try await leg(
                from: waypoints[0], to: waypoints[1], transportType: transportType,
                avoidTolls: avoidTolls, avoidHighways: avoidHighways, alternates: true
            )
        }

        var allCoordinates: [CLLocationCoordinate2D] = []
        var totalTime: TimeInterval = 0
        var totalDistance: Double = 0
        var allSteps: [RouteStep] = []
        for i in 0..<(waypoints.count - 1) {
            let legOptions = try await leg(
                from: waypoints[i], to: waypoints[i + 1], transportType: transportType,
                avoidTolls: avoidTolls, avoidHighways: avoidHighways, alternates: false
            )
            guard let onlyRoute = legOptions.first else { throw RouteError.noRoute }
            allCoordinates.append(contentsOf: onlyRoute.coordinates)
            totalTime += onlyRoute.travelTime
            totalDistance += onlyRoute.distanceMeters
            allSteps.append(contentsOf: onlyRoute.steps)
        }

        return [RouteOption(
            coordinates: allCoordinates,
            travelTime: totalTime,
            distanceMeters: totalDistance,
            summary: "Route with \(stops.count) stop\(stops.count == 1 ? "" : "s")",
            transitSteps: [],
            steps: allSteps
        )]
    }

    private func leg(
        from origin: MKMapItem,
        to destination: MKMapItem,
        transportType: MKDirectionsTransportType,
        avoidTolls: Bool,
        avoidHighways: Bool,
        alternates: Bool
    ) async throws -> [RouteOption] {
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = transportType
        request.requestsAlternateRoutes = alternates
        if transportType == .automobile {
            request.tollPreference = avoidTolls ? .avoid : .any
            request.highwayPreference = avoidHighways ? .avoid : .any
        }

        let response = try await MKDirections(request: request).calculate()
        return response.routes.map { route in
            RouteOption(
                coordinates: route.coordinates,
                travelTime: route.expectedTravelTime,
                distanceMeters: route.distance,
                summary: route.name.isEmpty ? "Route" : "via \(route.name)",
                transitSteps: [],
                steps: route.steps.map { step in
                    RouteStep(instruction: step.instructions, distanceMeters: step.distance, maneuver: nil)
                }
            )
        }
    }
}
