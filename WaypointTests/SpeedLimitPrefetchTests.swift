import CoreLocation
import XCTest
@testable import Waypoint

/// The prefetched speed-limit table is what keeps the sign up in a tunnel, so the two pieces it's
/// built out of — sampling the road ahead, and matching a position back to a road — are pinned
/// down here.
@MainActor
final class SpeedLimitPrefetchTests: XCTestCase {

    /// Roughly 111m per 0.001° of latitude, so a 200m spacing should take about every other point
    /// off a line of them.
    func testSamplesAlongTheRouteAtRoughlyTheRequestedSpacing() {
        let line = (0..<20).map {
            CLLocationCoordinate2D(latitude: 40.700 + Double($0) * 0.001, longitude: -73.950)
        }

        let samples = SpeedLimitService.sample(line, everyMetres: 200, upToMetres: 100_000)

        XCTAssertEqual(samples.first?.latitude, 40.700)
        XCTAssertGreaterThan(samples.count, 8)
        XCTAssertLessThan(samples.count, 13)
    }

    /// A long route is only pulled a stretch at a time; sampling has to stop at the window rather
    /// than thinning out to cover the whole thing.
    func testStopsSamplingAtTheWindowLength() {
        let line = (0..<400).map {
            CLLocationCoordinate2D(latitude: 40.700 + Double($0) * 0.001, longitude: -73.950)
        }

        let samples = SpeedLimitService.sample(line, everyMetres: 200, upToMetres: 5_000)
        guard let last = samples.last else { return XCTFail("expected samples") }

        let covered = CLLocation(latitude: 40.700, longitude: -73.950)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
        XCTAssertLessThan(covered, 5_500)
        XCTAssertGreaterThan(covered, 4_500)
    }

    func testHandlesAnEmptyOrSinglePointRoute() {
        XCTAssertTrue(SpeedLimitService.sample([], everyMetres: 200, upToMetres: 1_000).isEmpty)
        let single = [CLLocationCoordinate2D(latitude: 40.7, longitude: -73.95)]
        XCTAssertEqual(SpeedLimitService.sample(single, everyMetres: 200, upToMetres: 1_000).count, 1)
    }

    /// Matching to the road rather than to its endpoints — the same reason the incident check
    /// projects onto segments.
    func testMeasuresToTheRoadNotItsEndpoints() {
        let road = [
            CLLocationCoordinate2D(latitude: 40.700, longitude: -73.950),
            CLLocationCoordinate2D(latitude: 40.740, longitude: -73.950),
        ]
        let alongside = CLLocationCoordinate2D(latitude: 40.720, longitude: -73.9501)

        XCTAssertLessThan(SpeedLimitService.distance(from: alongside, to: road), 20)
        XCTAssertGreaterThan(
            SpeedLimitService.distance(
                from: CLLocationCoordinate2D(latitude: 40.720, longitude: -73.960), to: road
            ),
            500
        )
    }
}
