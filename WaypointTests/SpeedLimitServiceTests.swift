import CoreLocation
import XCTest
@testable import Waypoint

/// The live cases here hit Overpass and NYC Open Data on purpose. The whole point of the feature
/// is that a real posted limit comes back for a real street, and a mocked response would have
/// happily "passed" while the sign stayed blank on the road — which is exactly what happened the
/// first time round.
///
/// They're opt-in (`TEST_RUNNER_WAYPOINT_LIVE_TESTS=1` — xcodebuild only forwards variables with
/// that prefix into the test process, and strips it on the way in) because both endpoints are
/// free, shared and
/// unauthenticated: run back to back they rate-limit each other, and the last one gets a 12s
/// timeout instead of an answer. That's the endpoint being busy, not the feature being broken,
/// and it shouldn't be able to redden an ordinary run of the suite.
final class SpeedLimitServiceTests: XCTestCase {

    private func requireLiveEndpoints() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAYPOINT_LIVE_TESTS"] == "1",
                          "Set TEST_RUNNER_WAYPOINT_LIVE_TESTS=1 to hit Overpass and NYC Open Data")
    }

    /// McKibbin St, Brooklyn. OSM has no `maxspeed` here at all, so this only resolves if the
    /// NYC DOT fallback is working.
    @MainActor
    func testResolvesLimitOnBrooklynResidentialStreet() async throws {
        try requireLiveEndpoints()
        let service = SpeedLimitService()
        await service.refreshIfNeeded(at: CLLocation(latitude: 40.7052, longitude: -73.9385))

        let display = try XCTUnwrap(service.display, "No speed limit resolved for McKibbin St")
        XCTAssertEqual(display.unit, "mph")
        XCTAssertEqual(display.value, 25)
    }

    /// 5th Avenue, Manhattan — tagged in OSM, so this covers the primary source.
    @MainActor
    func testResolvesLimitFromOpenStreetMap() async throws {
        try requireLiveEndpoints()
        let service = SpeedLimitService()
        await service.refreshIfNeeded(at: CLLocation(latitude: 40.7411, longitude: -73.9897))

        let display = try XCTUnwrap(service.display, "No speed limit resolved for 5th Ave")
        XCTAssertGreaterThan(display.value, 0)
        XCTAssertLessThanOrEqual(display.value, 65)
    }

    @MainActor
    func testResetClearsTheSign() async throws {
        try requireLiveEndpoints()
        let service = SpeedLimitService()
        await service.refreshIfNeeded(at: CLLocation(latitude: 40.7052, longitude: -73.9385))
        XCTAssertNotNil(service.display, "Nothing to clear — the fetch didn't resolve")
        service.reset()
        XCTAssertNil(service.display)
    }

    func testParsesTheMaxspeedTagFormsOSMActuallyUses() {
        XCTAssertEqual(SpeedLimitService.parseMaxspeed("25 mph"), 40)
        XCTAssertEqual(SpeedLimitService.parseMaxspeed("50"), 50)
        // Presets carry no number, so there's nothing honest to show.
        XCTAssertNil(SpeedLimitService.parseMaxspeed("US:urban"))
        XCTAssertNil(SpeedLimitService.parseMaxspeed("none"))
        XCTAssertNil(SpeedLimitService.parseMaxspeed("30 knots"))
    }
}
