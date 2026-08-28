import XCTest
@testable import Waypoint

/// SIRI's response nests four levels deep with capitalised keys, so this runs against the live
/// feed rather than a fixture — a decode that silently yields nothing looks identical to "no
/// buses running" otherwise.
@MainActor
final class MTABusRealtimeTests: XCTestCase {
    func testDecodesLiveB43Arrivals() async throws {
        let service = MTABusRealtimeService()
        try XCTSkipUnless(service.isConfigured, "MTA_BUS_TIME_API_KEY not set")

        // Box St/Manhattan Av — the northern end of the B43, which runs frequently.
        await service.load(line: "B43", boardingStopID: "MTA_305287")

        XCTAssertFalse(service.arrivals.isEmpty,
                       "Expected live B43 arrivals — empty means the SIRI decode failed")
        let minutes = service.arrivals.map(\.minutesAway)
        XCTAssertEqual(minutes, minutes.sorted(), "Arrivals should be chronological")
        XCTAssertTrue(minutes.allSatisfy { $0 < 180 }, "Arrivals should be soon, got \(minutes)")
    }

    func testMissingKeyStaysSilentRatherThanErroring() async {
        let service = MTABusRealtimeService()
        await service.load(line: "B43", boardingStopID: "MTA_000000")
        // A stop with no service must not invent arrivals.
        XCTAssertTrue(service.arrivals.isEmpty)
    }
}
