import CoreLocation
import MapKit
import XCTest
@testable import Waypoint

/// Where the rider is, how far the next turn is, and how long is left — the three numbers the
/// whole navigation UI is built on. Each of them used to be measured against the nearest
/// *vertex* of the route or a step boundary guessed by cutting the route into equal pieces,
/// which is fine on a dense city polyline and badly wrong on a highway.
@MainActor
final class NavigationAccuracyTests: XCTestCase {
    /// ~111m per 0.001° of latitude, so a ladder of points is a ladder of known distances.
    private func ladder(_ count: Int, spacing: Double = 0.001) -> [CLLocationCoordinate2D] {
        (0..<count).map { CLLocationCoordinate2D(latitude: 40.70 + Double($0) * spacing, longitude: -73.90) }
    }

    /// 10m east of the given point — about the sideways error of a decent city GPS fix.
    private func offset(_ coordinate: CLLocationCoordinate2D, metresEast: Double) -> CLLocationCoordinate2D {
        let degrees = metresEast / (111_320 * cos(coordinate.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude + degrees)
    }

    private func route(_ coordinates: [CLLocationCoordinate2D], steps: [RouteStep] = []) -> RouteOption {
        var option = RouteOption(
            coordinates: coordinates,
            travelTime: 600,
            distanceMeters: 1113,
            summary: "Test",
            transitSteps: []
        )
        option.steps = steps
        return option
    }

    /// A mile of straight highway is two polyline points. Sitting in the middle of it, the
    /// nearest point is half a mile away — which used to be read as being half a mile off route.
    func testDrivingDownALongStraightIsNotOffRoute() throws {
        let ends = [
            CLLocationCoordinate2D(latitude: 40.700, longitude: -73.900),
            CLLocationCoordinate2D(latitude: 40.710, longitude: -73.900),
        ]
        let navigation = NavigationViewModel()
        var rerouted = false
        navigation.onOffRoute = { rerouted = true }
        navigation.start(route: route(ends), destinationName: "End", destinationCoordinate: ends[1])

        let middle = CLLocationCoordinate2D(latitude: 40.705, longitude: -73.900)
        let fix = CLLocation(latitude: middle.latitude, longitude: offset(middle, metresEast: 10).longitude)
        navigation.update(with: fix)
        navigation.update(with: fix)

        XCTAssertFalse(rerouted, "10m to the side of a straight road is on the road")
        // Half of ~1113m.
        XCTAssertEqual(navigation.remainingDistance, 556, accuracy: 20)
        let matched = try XCTUnwrap(navigation.matchedCoordinate, "A fix this close to the line should be pulled onto it")
        XCTAssertEqual(matched.latitude, middle.latitude, accuracy: 0.0002)
        XCTAssertEqual(matched.longitude, -73.900, accuracy: 0.00002, "Matched sideways onto the road, not left out in the field")
    }

    /// The honesty half of the same rule: a fix that genuinely disagrees with the route is drawn
    /// where the phone says it is, not dragged onto the line to look tidy.
    func testAFixWellOffTheRouteIsLeftWhereItIs() {
        let coordinates = ladder(11)
        let navigation = NavigationViewModel()
        navigation.start(route: route(coordinates), destinationName: "End", destinationCoordinate: coordinates[10])

        let strayed = offset(coordinates[5], metresEast: 200)
        navigation.update(with: CLLocation(latitude: strayed.latitude, longitude: strayed.longitude))

        XCTAssertNil(navigation.matchedCoordinate)
    }

    /// Steps are never equal-length, so cutting the polyline into equal slices put the turn in
    /// the wrong place. With the step's own start coordinate the banner counts down to where the
    /// turn actually is.
    func testDistanceToTheNextTurnComesFromTheStepsOwnGeometry() throws {
        let coordinates = ladder(11)
        let steps = [
            RouteStep(instruction: "Head north", distanceMeters: 890, startCoordinate: coordinates[0]),
            RouteStep(instruction: "Turn right", distanceMeters: 223, startCoordinate: coordinates[8]),
        ]
        let navigation = NavigationViewModel()
        navigation.start(route: route(coordinates, steps: steps), destinationName: "End", destinationCoordinate: coordinates[10])
        navigation.update(with: CLLocation(latitude: coordinates[2].latitude, longitude: coordinates[2].longitude))

        // Six points of ~111m between where you are and where the turn is. The equal-slice guess
        // would have put that turn at point 5, i.e. ~334m.
        let toTurn = try XCTUnwrap(navigation.distanceToNextManeuver)
        XCTAssertEqual(toTurn, 667, accuracy: 25)
        XCTAssertEqual(navigation.currentStepIndex, 0, "Still on the first step until you reach the turn")
    }

    func testReachingTheTurnAdvancesTheBanner() {
        let coordinates = ladder(11)
        let steps = [
            RouteStep(instruction: "Head north", distanceMeters: 890, startCoordinate: coordinates[0]),
            RouteStep(instruction: "Turn right", distanceMeters: 223, startCoordinate: coordinates[8]),
        ]
        let navigation = NavigationViewModel()
        var spoken: [String] = []
        navigation.onAnnouncement = { spoken.append($0) }
        navigation.start(route: route(coordinates, steps: steps), destinationName: "End", destinationCoordinate: coordinates[10])
        navigation.update(with: CLLocation(latitude: coordinates[8].latitude, longitude: coordinates[8].longitude))

        XCTAssertEqual(navigation.currentStepIndex, 1)
        XCTAssertTrue(spoken.contains("Turn right"), "Spoken at the turn: \(spoken)")
    }

    /// A transit trip's legs don't move at one speed, so scaling the whole trip's time by how
    /// much distance is left says the 700m walk to the station takes as long as 700m of express
    /// track. Each leg's own duration is what's left of it plus everything after.
    func testTransitTimeLeftIsSummedFromTheLegs() {
        let coordinates = ladder(30)
        var option = RouteOption(
            coordinates: coordinates,
            travelTime: 9_999,  // deliberately nothing like the legs, to prove it isn't used
            distanceMeters: 3_230,
            summary: "via J",
            transitSteps: []
        )
        option.transitSegments = [
            TransitSegment(
                coordinates: Array(coordinates[0..<10]), range: 0..<10,
                isWalk: true, lineLabel: nil, providerColor: nil, isSubway: false, seconds: 600
            ),
            TransitSegment(
                coordinates: Array(coordinates[9..<30]), range: 10..<30,
                isWalk: false, lineLabel: "J", providerColor: nil, isSubway: true, seconds: 900
            ),
        ]

        let navigation = NavigationViewModel()
        navigation.start(route: option, destinationName: "Fulton St", destinationCoordinate: coordinates[29])

        navigation.update(with: CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude))
        XCTAssertEqual(navigation.remainingTime, 1_500, accuracy: 40, "The whole walk plus the whole ride")

        // Fourteen of the ride's nineteen point-gaps still ahead.
        navigation.update(with: CLLocation(latitude: coordinates[15].latitude, longitude: coordinates[15].longitude))
        XCTAssertEqual(navigation.remainingTime, 900 * 14.0 / 19.0, accuracy: 60, "Only what's left of the ride")
    }

    /// Without per-leg durations there's nothing to sum, so it falls back to the old
    /// distance-proportional estimate rather than inventing one.
    func testTimeLeftFallsBackToDistanceWhenLegsAreUntimed() {
        let coordinates = ladder(21)
        var option = RouteOption(
            coordinates: coordinates, travelTime: 1_000, distanceMeters: 2_226,
            summary: "via J", transitSteps: []
        )
        option.transitSegments = [
            TransitSegment(
                coordinates: coordinates, range: 0..<21,
                isWalk: false, lineLabel: "J", providerColor: nil, isSubway: true
            )
        ]
        let navigation = NavigationViewModel()
        navigation.start(route: option, destinationName: "Fulton St", destinationCoordinate: coordinates[20])
        navigation.update(with: CLLocation(latitude: coordinates[10].latitude, longitude: coordinates[10].longitude))

        XCTAssertEqual(navigation.remainingTime, 500, accuracy: 40)
    }
}

/// The card that rides with you: which leg you're on, the station you're pulling into, and how
/// many are left. Built on the real bundled MTA stop sequence rather than a fixture, because a
/// stop list that silently resolves to nothing looks the same as a quiet ride otherwise.
@MainActor
final class TransitProgressTests: XCTestCase {
    private struct Trip {
        let route: RouteOption
        let stops: [(stop: MTASubwayData.Stop, minutesFromBoarding: Int)]
        let walkPoints: Int
    }

    /// Flushing Av to Fulton St on the J — the ride from the screenshots the transit work
    /// started from — with a short walk to the platform in front of it.
    private func flushingToFultonOnTheJ() throws -> Trip {
        let stops = try XCTUnwrap(
            MTASubwayData.intermediateStops(line: "J", from: "Flushing Av", to: "Fulton St"),
            "The bundled MTA data should resolve this ride"
        )
        let rideCoordinates = stops.map(\.stop.coordinate)
        let first = try XCTUnwrap(rideCoordinates.first)
        // Three points of pavement leading into the station entrance.
        let walkCoordinates = (1...3).reversed().map {
            CLLocationCoordinate2D(latitude: first.latitude - Double($0) * 0.0005, longitude: first.longitude)
        }
        let coordinates = walkCoordinates + rideCoordinates

        let ride = TransitStep(
            lineName: "J", lineShortName: "J", vehicle: "SUBWAY",
            departureStop: "Flushing Av", arrivalStop: "Fulton St",
            numStops: stops.count, headsign: "Broad St", color: nil
        )
        var route = RouteOption(
            coordinates: coordinates, travelTime: 1_500, distanceMeters: 8_000,
            summary: "via J", transitSteps: [ride]
        )
        route.transitSegments = [
            TransitSegment(
                coordinates: walkCoordinates, range: 0..<walkCoordinates.count,
                isWalk: true, lineLabel: nil, providerColor: nil, isSubway: false
            ),
            TransitSegment(
                coordinates: Array(coordinates[(walkCoordinates.count - 1)...]),
                range: walkCoordinates.count..<coordinates.count,
                isWalk: false, lineLabel: "J", providerColor: nil, isSubway: true, rideIndex: 0
            ),
        ]
        return Trip(route: route, stops: stops, walkPoints: walkCoordinates.count)
    }

    func testWalkingToThePlatformNamesTheTrainYoureCatching() throws {
        let trip = try flushingToFultonOnTheJ()
        let navigation = NavigationViewModel()
        navigation.start(route: trip.route, destinationName: "Fulton St", destinationCoordinate: trip.route.coordinates.last!)
        let start = trip.route.coordinates[0]
        navigation.update(with: CLLocation(latitude: start.latitude, longitude: start.longitude))

        XCTAssertNil(navigation.currentRide, "Still on foot")
        XCTAssertEqual(navigation.upcomingRide?.displayLine, "J")
        XCTAssertNil(navigation.stopsUntilExit, "Stop counts belong to a ride you're on")
    }

    func testRidingTheJNamesTheNextStopAndCountsWhatsLeft() throws {
        let trip = try flushingToFultonOnTheJ()
        let navigation = NavigationViewModel()
        navigation.start(route: trip.route, destinationName: "Fulton St", destinationCoordinate: trip.route.coordinates.last!)

        // Sitting at the second station of the ride.
        let onboard = trip.route.coordinates[trip.walkPoints + 1]
        navigation.update(with: CLLocation(latitude: onboard.latitude, longitude: onboard.longitude))

        XCTAssertEqual(navigation.currentRide?.displayLine, "J", "You're on the train now")
        XCTAssertNil(navigation.upcomingRide, "Nothing to transfer to on this trip")
        XCTAssertEqual(navigation.nextStopName, trip.stops[2].stop.name)
        XCTAssertEqual(navigation.stopsUntilExit, trip.stops.count - 2)
    }

    func testTheLastStopIsTheOneYouGetOffAt() throws {
        let trip = try flushingToFultonOnTheJ()
        let navigation = NavigationViewModel()
        navigation.start(route: trip.route, destinationName: "Fulton St", destinationCoordinate: trip.route.coordinates.last!)

        let secondToLast = trip.route.coordinates[trip.route.coordinates.count - 2]
        navigation.update(with: CLLocation(latitude: secondToLast.latitude, longitude: secondToLast.longitude))

        XCTAssertEqual(navigation.nextStopName, trip.stops.last?.stop.name, "Fulton St is next")
        XCTAssertEqual(navigation.stopsUntilExit, 1)
    }
}
