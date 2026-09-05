import CoreLocation
import XCTest
@testable import Waypoint

/// The banner counts down a distance and names a turn. Those two have to be the *same* turn.
///
/// They weren't: a step's instruction describes the maneuver at the end of that step, and the UI
/// read one step ahead of the one it was measuring to. On a route with two turns close together
/// that meant being told to turn right onto the street after the left you were 50 metres from —
/// out loud, and on the banner.
@MainActor
final class ManeuverPairingTests: XCTestCase {
    /// North up Boerum Pl, left onto Dean St at J1, right onto Hoyt St at J2.
    private func route() -> (RouteOption, [CLLocationCoordinate2D]) {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 40.6880, longitude: -73.9900),
            CLLocationCoordinate2D(latitude: 40.6885, longitude: -73.9900),
            CLLocationCoordinate2D(latitude: 40.6890, longitude: -73.9900),  // J1
            CLLocationCoordinate2D(latitude: 40.6890, longitude: -73.9908),
            CLLocationCoordinate2D(latitude: 40.6890, longitude: -73.9915),  // J2
            CLLocationCoordinate2D(latitude: 40.6895, longitude: -73.9915),
            CLLocationCoordinate2D(latitude: 40.6900, longitude: -73.9915),
        ]
        let option = RouteOption(
            coordinates: coordinates,
            travelTime: 300,
            distanceMeters: 500,
            summary: "test",
            transitSteps: [],
            steps: [
                RouteStep(instruction: "Turn left onto Dean St", distanceMeters: 110,
                          startCoordinate: coordinates[0], maneuver: "TURN_LEFT"),
                RouteStep(instruction: "Turn right onto Hoyt St", distanceMeters: 130,
                          startCoordinate: coordinates[2], maneuver: "TURN_RIGHT"),
                RouteStep(instruction: "Arrive at the destination", distanceMeters: 110,
                          startCoordinate: coordinates[4], maneuver: nil),
            ]
        )
        return (option, coordinates)
    }

    func testNamesTheTurnItIsCountingDownTo() throws {
        let (option, coordinates) = route()
        let navigation = NavigationViewModel()
        navigation.start(route: option, destinationName: "X", destinationCoordinate: coordinates[6])

        // Halfway up Boerum Pl, approaching the left onto Dean St.
        navigation.update(with: CLLocation(latitude: 40.6885, longitude: -73.9900))

        let distance = try XCTUnwrap(navigation.distanceToNextManeuver)
        XCTAssertEqual(distance, 55, accuracy: 15, "should be measuring to the Dean St junction")
        XCTAssertEqual(navigation.currentStep?.instruction, "Turn left onto Dean St")
        XCTAssertEqual(navigation.currentStep?.maneuverIcon, "arrow.turn.up.left")
        // And the "Then" line is the one after it.
        XCTAssertEqual(navigation.nextStep?.instruction, "Turn right onto Hoyt St")
    }

    /// Past the first junction the pairing has to shift with it, not lag a turn behind.
    func testAdvancesToTheFollowingTurnAfterTheJunction() {
        let (option, coordinates) = route()
        let navigation = NavigationViewModel()
        navigation.start(route: option, destinationName: "X", destinationCoordinate: coordinates[6])
        navigation.update(with: CLLocation(latitude: 40.6885, longitude: -73.9900))
        // Now on Dean St, between the two junctions.
        navigation.update(with: CLLocation(latitude: 40.6890, longitude: -73.9908))

        XCTAssertEqual(navigation.currentStep?.instruction, "Turn right onto Hoyt St")
        XCTAssertEqual(navigation.nextStep?.instruction, "Arrive at the destination")
    }

    /// The spoken countdown has to name the same turn the banner does.
    func testSpeaksTheTurnItIsApproaching() {
        let (option, coordinates) = route()
        let navigation = NavigationViewModel()
        var spoken: [String] = []
        navigation.onAnnouncement = { spoken.append($0) }
        navigation.start(route: option, destinationName: "X", destinationCoordinate: coordinates[6])
        navigation.update(with: CLLocation(latitude: 40.6885, longitude: -73.9900))

        let countdown = spoken.first { $0.hasPrefix("In ") }
        XCTAssertNotNil(countdown, "should pre-announce the upcoming turn")
        XCTAssertTrue(
            countdown?.contains("Turn left onto Dean St") == true,
            "announced the wrong turn: \(countdown ?? "-")"
        )
    }
}
