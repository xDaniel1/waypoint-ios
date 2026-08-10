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
        avoidHighways: Bool = false,
        departureDate: Date? = nil,
        arrivalDate: Date? = nil
    ) async throws -> [RouteOption] {
        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        let waypoints = [originItem] + stops + [destination]

        guard waypoints.count > 2 else {
            return try await leg(
                from: waypoints[0], to: waypoints[1], transportType: transportType,
                avoidTolls: avoidTolls, avoidHighways: avoidHighways, 
                departureDate: departureDate, arrivalDate: arrivalDate, alternates: true
            )
        }

        var allCoordinates: [CLLocationCoordinate2D] = []
        var totalTime: TimeInterval = 0
        var totalDistance: Double = 0
        var allSteps: [RouteStep] = []
        for i in 0..<(waypoints.count - 1) {
            let legOptions = try await leg(
                from: waypoints[i], to: waypoints[i + 1], transportType: transportType,
                avoidTolls: avoidTolls, avoidHighways: avoidHighways, 
                departureDate: departureDate, arrivalDate: arrivalDate, alternates: false
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
        departureDate: Date? = nil,
        arrivalDate: Date? = nil,
        alternates: Bool
    ) async throws -> [RouteOption] {
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = transportType
        request.requestsAlternateRoutes = alternates
        request.departureDate = departureDate
        request.arrivalDate = arrivalDate
        if transportType == .automobile {
            request.tollPreference = avoidTolls ? .avoid : .any
            request.highwayPreference = avoidHighways ? .avoid : .any
        }

        let response = try await MKDirections(request: request).calculate()

        // `MKRoute.expectedTravelTime` is explicitly documented as travel time under *ideal*
        // conditions — it ignores traffic entirely, so ETAs built on it run optimistic. Only
        // `calculateETA()` returns a traffic-aware figure, so ask for it once for this leg and
        // use it to scale the per-route times (the ETA call has no notion of which alternate you
        // meant, so it corresponds to the primary route).
        let trafficFactor = await Self.trafficFactor(for: request, primary: response.routes.first)

        return response.routes.map { route in
            RouteOption(
                coordinates: route.coordinates,
                travelTime: route.expectedTravelTime * trafficFactor,
                distanceMeters: route.distance,
                summary: route.name.isEmpty ? "Route" : "via \(route.name)",
                transitSteps: [],
                steps: route.steps.map { step in
                    RouteStep(instruction: step.instructions, distanceMeters: step.distance, maneuver: nil)
                },
                // Only claim traffic when it's actually slowing things down enough to notice;
                // this drives the orange duration + car-with-exclamation badge on the card.
                hasTraffic: trafficFactor > 1.15
            )
        }
    }

    /// Ratio of the traffic-aware ETA to the ideal-conditions time for the same leg, so alternates
    /// can be adjusted by the same real-world factor. Falls back to 1 (no adjustment) if the ETA
    /// request fails or returns something implausible, rather than distorting every route.
    private static func trafficFactor(for request: MKDirections.Request, primary: MKRoute?) async -> Double {
        guard let primary, primary.expectedTravelTime > 0 else { return 1 }

        // calculateETA needs its own request object: a single MKDirections can only run one
        // request at a time, and the routes call above already consumed this one.
        let etaRequest = MKDirections.Request()
        etaRequest.source = request.source
        etaRequest.destination = request.destination
        etaRequest.transportType = request.transportType
        etaRequest.tollPreference = request.tollPreference
        etaRequest.highwayPreference = request.highwayPreference

        guard let eta = try? await MKDirections(request: etaRequest).calculateETA() else { return 1 }
        let factor = eta.expectedTravelTime / primary.expectedTravelTime
        // Guard against nonsense (a wildly different route matched, or a bad response) — anything
        // outside "no faster than ideal, no worse than 3x" is treated as untrustworthy.
        guard factor.isFinite, factor >= 1, factor <= 3 else { return 1 }
        return factor
    }
}
