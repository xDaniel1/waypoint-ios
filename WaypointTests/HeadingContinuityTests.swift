import CoreLocation
import MapKit
import SwiftUI
import XCTest
@testable import Waypoint

/// `MapCamera` keeps whatever heading it is handed — it does not fold the value into 0..<360,
/// which the first test here records because the whole fix depends on it. SwiftUI then animates
/// between the two raw numbers, so 350° -> 10° rotates the long way unless we rephrase it.
final class HeadingContinuityTests: XCTestCase {

    func testMapCameraStoresHeadingsVerbatimRatherThanNormalising() {
        let here = CLLocationCoordinate2D(latitude: 40.68, longitude: -73.94)
        // If this ever starts failing, MapKit began normalising and `shortWay` is dead weight.
        XCTAssertEqual(MapCamera(centerCoordinate: here, distance: 500, heading: 370, pitch: 55).heading, 370)
        XCTAssertEqual(MapCamera(centerCoordinate: here, distance: 500, heading: -10, pitch: 55).heading, -10)
    }

    func testTurningThroughNorthGoesForwardsNotAllTheWayRound() {
        // Driving north-north-west onto a north-north-east road: a 20° turn, not a 340° one.
        XCTAssertEqual(MapViewModel.shortWay(to: 10, from: 350), 370)
    }

    func testTurningBackThroughNorthGoesBackwards() {
        XCTAssertEqual(MapViewModel.shortWay(to: 350, from: 10), -10)
    }

    func testStraighteningToNorthFromTheWestTakesTheShortWay() {
        // The location button's third tap, with the map sitting at 350°: a 10° nudge, not a
        // 350° spin back through south.
        XCTAssertEqual(MapViewModel.shortWay(to: 0, from: 350), 360)
    }

    func testAnOrdinaryTurnIsLeftAlone() {
        XCTAssertEqual(MapViewModel.shortWay(to: 90, from: 45), 90)
        XCTAssertEqual(MapViewModel.shortWay(to: 45, from: 90), 45)
    }

    /// A half turn is the one case with no shorter direction; it just has to not blow up or
    /// wander further than 180° away.
    func testHalfTurnStaysWithinHalfATurn() {
        XCTAssertEqual(abs(MapViewModel.shortWay(to: 180, from: 0) - 0), 180, accuracy: 0.001)
    }

    func testHeadingsStayContinuousAcrossRepeatedLapsRatherThanSnappingBack() {
        // Circling a roundabout: each step is a real 90° turn in the same direction, so the
        // commanded value should keep climbing instead of resetting at north.
        var current: CLLocationDirection = 0
        for target in [90.0, 180.0, 270.0, 0.0, 90.0] {
            let next = MapViewModel.shortWay(to: target, from: current)
            XCTAssertEqual(abs(next - current), 90, accuracy: 0.001,
                           "Every leg of the roundabout is a quarter turn")
            current = next
        }
        XCTAssertEqual(current, 450, "Ended up one and a quarter laps round, not back at 90")
    }

    @MainActor
    func testTheFollowCameraTurnsTheShortWayOnConsecutiveFixes() {
        let viewModel = MapViewModel()
        let here = CLLocation(latitude: 40.68, longitude: -73.94)

        viewModel.followUser(at: here, heading: 350, speed: 12)
        let before = try? XCTUnwrap(cameraHeading(of: viewModel))
        viewModel.followUser(at: here, heading: 10, speed: 12)
        let after = try? XCTUnwrap(cameraHeading(of: viewModel))

        guard let before = before ?? nil, let after = after ?? nil else {
            return XCTFail("Expected a camera position with a heading")
        }
        XCTAssertEqual(after - before, 20, accuracy: 0.001,
                       "A 20° turn through north must command a 20° change, not -340°")
    }

    @MainActor
    private func cameraHeading(of viewModel: MapViewModel) -> CLLocationDirection? {
        viewModel.cameraPosition.camera?.heading
    }
}
