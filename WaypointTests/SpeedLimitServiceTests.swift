import CoreLocation
import XCTest
@testable import Waypoint

/// These hit the live Overpass and NYC Open Data endpoints on purpose. The whole point of the
/// feature is that a real posted limit comes back for a real street, and a mocked response would
/// have happily "passed" while the sign stayed blank on the road — which is exactly what happened
/// the first time round.
final class SpeedLimitServiceTests: XCTestCase {
    /// McKibbin St, Brooklyn. OSM has no `maxspeed` here at all, so this only resolves if the
    /// NYC DOT fallback is working.
    @MainActor
    func testResolvesLimitOnBrooklynResidentialStreet() async throws {
        let service = SpeedLimitService()
        await service.refreshIfNeeded(at: CLLocation(latitude: 40.7052, longitude: -73.9385))

        let display = try XCTUnwrap(service.display, "No speed limit resolved for McKibbin St")
        XCTAssertEqual(display.unit, "mph")
        XCTAssertEqual(display.value, 25)
    }

    /// 5th Avenue, Manhattan — tagged in OSM, so this covers the primary source.
    @MainActor
    func testResolvesLimitFromOpenStreetMap() async throws {
        let service = SpeedLimitService()
        await service.refreshIfNeeded(at: CLLocation(latitude: 40.7411, longitude: -73.9897))

        let display = try XCTUnwrap(service.display, "No speed limit resolved for 5th Ave")
        XCTAssertGreaterThan(display.value, 0)
        XCTAssertLessThanOrEqual(display.value, 65)
    }

    func testParsesTheMaxspeedTagFormsOSMActuallyUses() {
        XCTAssertEqual(SpeedLimitService.parseMaxspeed("25 mph"), 40)
        XCTAssertEqual(SpeedLimitService.parseMaxspeed("50"), 50)
        // Presets carry no number, so there's nothing honest to show.
        XCTAssertNil(SpeedLimitService.parseMaxspeed("US:urban"))
        XCTAssertNil(SpeedLimitService.parseMaxspeed("none"))
        XCTAssertNil(SpeedLimitService.parseMaxspeed("30 knots"))
    }

    @MainActor
    func testResetClearsTheSign() async {
        let service = SpeedLimitService()
        await service.refreshIfNeeded(at: CLLocation(latitude: 40.7052, longitude: -73.9385))
        service.reset()
        XCTAssertNil(service.display)
    }
}
