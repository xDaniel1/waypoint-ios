import XCTest
@testable import Waypoint

@MainActor
final class MTABusRealtimeTests: XCTestCase {

    /// A trimmed real stop-monitoring body: two buses due, one already gone, and the two
    /// timestamp shapes Bus Time mixes (fractional seconds on one call, none on the next).
    private func feed(now: Date) -> Data {
        func stamp(_ offsetMinutes: Double, fractional: Bool) -> String {
            let date = now.addingTimeInterval(offsetMinutes * 60)
            let formatter = fractional ? Formatters.iso8601FractionalSeconds : Formatters.iso8601
            return formatter.string(from: date)
        }
        let json = """
        {"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"MonitoredStopVisit":[
          {"MonitoredVehicleJourney":{"MonitoredCall":{
            "ExpectedArrivalTime":"\(stamp(9, fractional: true))",
            "Extensions":{"Distances":{"StopsFromCall":4}}}}},
          {"MonitoredVehicleJourney":{"MonitoredCall":{
            "ExpectedArrivalTime":"\(stamp(3, fractional: false))",
            "Extensions":{"Distances":{"StopsFromCall":1}}}}},
          {"MonitoredVehicleJourney":{"MonitoredCall":{
            "AimedArrivalTime":"\(stamp(-20, fractional: true))"}}}
        ]}]}}}
        """
        return Data(json.utf8)
    }

    func testDecodesBothTimestampFormatsInArrivalOrder() throws {
        let now = Date()
        let arrivals = try XCTUnwrap(MTABusRealtimeService.arrivals(from: feed(now: now), now: now))

        XCTAssertEqual(arrivals.count, 2, "The bus that already left shouldn't be listed")
        XCTAssertEqual(arrivals.map(\.stopsAway), [1, 4], "Soonest bus first")
        XCTAssertEqual(arrivals[0].time.timeIntervalSince(now), 180, accuracy: 1)
        XCTAssertEqual(arrivals[1].time.timeIntervalSince(now), 540, accuracy: 1)
    }

    func testStopWithNoServiceDecodesToNoArrivalsRatherThanFailing() throws {
        let empty = Data(#"{"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[]}}}"#.utf8)
        XCTAssertEqual(MTABusRealtimeService.arrivals(from: empty, now: Date())?.count, 0)
    }

    func testNonSiriBodyIsReportedAsAFailureNotAsAnEmptyStop() {
        XCTAssertNil(MTABusRealtimeService.arrivals(from: Data(#"{"error":"bad key"}"#.utf8)))
    }

    func testMissingKeyStaysSilentRatherThanErroring() async {
        let service = MTABusRealtimeService()
        await service.load(line: "B43", boardingStopID: "MTA_000000")
        // A stop with no service must not invent arrivals.
        XCTAssertTrue(service.arrivals.isEmpty)
    }

    /// Opt-in: `TEST_RUNNER_WAYPOINT_LIVE_TESTS=1 xcodebuild test ...`. The prefix matters —
    /// xcodebuild only forwards variables named that way into the test process, and strips it on
    /// the way in, so a plain `WAYPOINT_LIVE_TESTS=1` silently skips instead of running.
    ///
    /// This talks to the real MTA, so it can fail for a bad key, an outage, or a route that
    /// genuinely isn't running — none of which mean the app is broken, and none of which should
    /// redden an ordinary run of the suite.
    func testDecodesLiveB43Arrivals() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAYPOINT_LIVE_TESTS"] == "1",
                          "Set TEST_RUNNER_WAYPOINT_LIVE_TESTS=1 to hit the live MTA feed")
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
}
