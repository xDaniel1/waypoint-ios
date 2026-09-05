import CoreLocation
import MapKit
import SwiftUI
import XCTest
@testable import Waypoint

/// What the location button is allowed to change about the camera, and what it must leave alone.
/// Apple's button answers "where am I" — it moves the map to you. It is not a zoom control and
/// it is not a 2D/3D control, so the zoom and the tilt you chose have to survive every tap and
/// every fix that arrives while it's following.
@MainActor
final class LocationButtonCameraTests: XCTestCase {

    private let here = CLLocation(latitude: 40.6782, longitude: -73.9442)

    /// A tilted, zoomed-in camera the user set by hand.
    private func tiltedCamera() -> MapCamera {
        MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 40.6, longitude: -73.9),
                  distance: 800, heading: 0, pitch: 55)
    }

    func testFirstTapKeepsTheZoomAndTiltYouWereAlreadyAt() {
        let viewModel = MapViewModel()
        viewModel.recenterOnUser(camera: tiltedCamera(), location: here)

        let camera = viewModel.cameraPosition.camera
        XCTAssertEqual(camera?.distance ?? 0, 800, accuracy: 1, "Recentring is not a zoom control")
        XCTAssertEqual(camera?.pitch ?? 0, 55, accuracy: 0.5, "Recentring is not a 2D/3D control")
    }

    /// The regression that made the button look broken in 3D: the tap itself kept the tilt, and
    /// then the next GPS fix — one second later — flattened the map.
    func testFollowingKeepsTheTiltFixAfterFix() {
        let viewModel = MapViewModel()
        var camera = tiltedCamera()

        for _ in 0..<3 {
            viewModel.recenterKeepingZoom(on: here, camera: camera)
            camera = try! XCTUnwrap(viewModel.cameraPosition.camera)
            XCTAssertEqual(camera.pitch, 55, accuracy: 0.5, "A fix must not flatten the map")
            XCTAssertEqual(camera.distance, 800, accuracy: 1, "A fix must not rescale the map")
        }
    }

    func testCompassModeKeepsZoomAndTiltAndOnlyTurnsTheMap() {
        let viewModel = MapViewModel()
        viewModel.orientToHeading(at: here, heading: 90, camera: tiltedCamera())

        let camera = viewModel.cameraPosition.camera
        XCTAssertEqual(camera?.distance ?? 0, 800, accuracy: 1)
        XCTAssertEqual(camera?.pitch ?? 0, 55, accuracy: 0.5)
        XCTAssertEqual(camera?.heading ?? 0, 90, accuracy: 0.5, "Facing east should point east up")
    }

    func testLeavingCompassModeKeepsZoomAndTilt() {
        let viewModel = MapViewModel()
        let rotated = MapCamera(centerCoordinate: here.coordinate, distance: 800, heading: 90, pitch: 55)
        viewModel.straightenToNorth(at: here, camera: rotated)

        let camera = viewModel.cameraPosition.camera
        XCTAssertEqual(camera?.distance ?? 0, 800, accuracy: 1)
        XCTAssertEqual(camera?.pitch ?? 0, 55, accuracy: 0.5)
    }

    /// Staring at the whole eastern seaboard, "where am I" should pick a useful zoom rather than
    /// faithfully preserving one that answers nothing.
    func testAnUselessZoomIsReplacedRatherThanPreserved() {
        let viewModel = MapViewModel()
        let continent = MapCamera(centerCoordinate: here.coordinate, distance: 3_000_000, heading: 0, pitch: 0)
        viewModel.recenterOnUser(camera: continent, location: here)

        let distance = viewModel.cameraPosition.camera?.distance ?? 0
        XCTAssertLessThan(distance, 10_000, "Should drop to something you can navigate by")
    }
}
