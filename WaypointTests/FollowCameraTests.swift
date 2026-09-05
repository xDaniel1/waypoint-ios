import CoreLocation
import MapKit
import XCTest
@testable import Waypoint

/// The navigation camera is the screen someone actually drives off, so the three things it has to
/// get right — point the way you're going, sit you low enough to see the road ahead, and pull back
/// as you speed up — are pinned down here rather than judged by eye.
@MainActor
final class FollowCameraTests: XCTestCase {
    private let brooklyn = CLLocation(latitude: 40.7000, longitude: -73.9500)

    func testTurnsTheMapToPointTheWayYouAreGoing() throws {
        let model = MapViewModel()
        model.followUser(at: brooklyn, heading: 90, speed: 10)

        let camera = try XCTUnwrap(model.cameraPosition.camera)
        XCTAssertEqual(camera.heading, 90, accuracy: 0.5)
        XCTAssertGreaterThan(camera.pitch, 1, "a driving camera is tilted, not flat")
    }

    /// The dot belongs low on the screen with the road ahead above it, which is done by centring
    /// the camera up the road rather than on the car.
    func testPlacesTheDriverBelowTheCentreOfTheMap() throws {
        let model = MapViewModel()
        model.followUser(at: brooklyn, heading: 0, speed: 10)

        let camera = try XCTUnwrap(model.cameraPosition.camera)
        // Heading north, so the centre should be north of the driver and on the same meridian.
        XCTAssertGreaterThan(camera.centerCoordinate.latitude, brooklyn.coordinate.latitude)
        XCTAssertEqual(camera.centerCoordinate.longitude, brooklyn.coordinate.longitude, accuracy: 0.0005)

        let offset = brooklyn.distance(
            from: CLLocation(
                latitude: camera.centerCoordinate.latitude,
                longitude: camera.centerCoordinate.longitude
            )
        )
        XCTAssertEqual(offset, camera.distance * MapViewModel.lookAheadFraction, accuracy: 20)
        // Far enough forward to matter, not so far the dot leaves the screen.
        XCTAssertGreaterThan(offset, 30)
        XCTAssertLessThan(offset, camera.distance * 0.4)
    }

    func testOffsetFollowsTheDirectionOfTravel() throws {
        let model = MapViewModel()
        model.followUser(at: brooklyn, heading: 270, speed: 10)

        let camera = try XCTUnwrap(model.cameraPosition.camera)
        // Heading west, so the look-ahead should be west of the driver.
        XCTAssertLessThan(camera.centerCoordinate.longitude, brooklyn.coordinate.longitude)
        XCTAssertEqual(camera.centerCoordinate.latitude, brooklyn.coordinate.latitude, accuracy: 0.0005)
    }

    /// The compass escape hatch: stop spinning the map, but keep the tilt and the road ahead.
    func testNorthUpStopsTheMapSpinningWithoutRecentringTheDriver() throws {
        let model = MapViewModel()
        model.followUser(at: brooklyn, heading: 135, speed: 10, northUp: true)

        let camera = try XCTUnwrap(model.cameraPosition.camera)
        XCTAssertEqual(camera.heading, 0, accuracy: 0.5)
        XCTAssertGreaterThan(camera.pitch, 1)
        // Still offset up the road — north-up is about rotation, not about burying the driver in
        // the middle of the screen.
        XCTAssertGreaterThan(
            brooklyn.distance(
                from: CLLocation(
                    latitude: camera.centerCoordinate.latitude,
                    longitude: camera.centerCoordinate.longitude
                )
            ),
            50
        )
    }

    func testPullsTheCameraBackAsSpeedRises() {
        let crawling = MapViewModel.followDistance(forSpeed: 2)
        let town = MapViewModel.followDistance(forSpeed: 10)
        let motorway = MapViewModel.followDistance(forSpeed: 30)

        XCTAssertLessThan(crawling, town)
        XCTAssertLessThan(town, motorway)
        XCTAssertEqual(crawling, 350, accuracy: 1, "a standstill shouldn't zoom further in than the floor")
        XCTAssertEqual(motorway, 1_100, accuracy: 1)
    }

    /// A stationary phone reports a speed of -1, which must not be read as "very slow" or, worse,
    /// pushed through the interpolation as a negative.
    func testIgnoresAnInvalidSpeedReading() {
        XCTAssertEqual(MapViewModel.followDistance(forSpeed: -1), 350, accuracy: 1)
    }

    func testProjectsACoordinateAlongABearing() {
        let north = MapViewModel.coordinate(from: brooklyn.coordinate, bearing: 0, metres: 500)
        let measured = brooklyn.distance(
            from: CLLocation(latitude: north.latitude, longitude: north.longitude)
        )

        XCTAssertEqual(measured, 500, accuracy: 5)
        XCTAssertGreaterThan(north.latitude, brooklyn.coordinate.latitude)
    }
}
