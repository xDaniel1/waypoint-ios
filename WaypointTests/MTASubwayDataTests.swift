import XCTest
@testable import Waypoint

/// The risk in this feature isn't the data, it's the join: Google names stations one way
/// ("Flushing Av") and the MTA another ("Flushing Avenue"). These use the exact stop names
/// Google's Routes API returned for real NYC trips.
@MainActor
final class MTASubwayDataTests: XCTestCase {
    func testResolvesTheJTrainStopsFromTheScreenshotTrip() throws {
        let stops = try XCTUnwrap(
            MTASubwayData.intermediateStops(line: "J", from: "Flushing Av", to: "Fulton St"),
            "The J train ride from Flushing Av to Fulton St should resolve"
        )
        let names = stops.map(\.stop.name)
        // Apple lists exactly these between Flushing Av and Fulton St.
        XCTAssertTrue(names.contains { $0.contains("Marcy") }, "Expected Marcy Av, got \(names)")
        XCTAssertTrue(names.contains { $0.contains("Canal") }, "Expected Canal St, got \(names)")
        XCTAssertEqual(names.last, "Fulton St")

        // Timings must increase away from the boarding stop.
        let minutes = stops.map(\.minutesFromBoarding)
        XCTAssertEqual(minutes, minutes.sorted(), "Stop timings should increase along the ride")
        XCTAssertGreaterThan(try XCTUnwrap(minutes.last), 0)
    }

    func testHandlesLineNamesGoogleActuallyReturns() {
        // Google labels these "L Line" / "G Line" rather than a bare letter.
        XCTAssertNotNil(MTASubwayData.intermediateStops(line: "L Line", from: "Bedford Av", to: "Union Sq-14 St"))
        XCTAssertNotNil(MTASubwayData.intermediateStops(line: "G", from: "Nassau Av", to: "Court Sq"))
    }

    func testResolvesBusStopsFromTheScreenshotTrip() throws {
        // Exactly the stop names Google returned for the B43 ride in the screenshots. MTA writes
        // them in caps ("GRAHAM AV/COOK ST"), Google in title case.
        let stops = try XCTUnwrap(
            MTASubwayData.intermediateStops(line: "B43", from: "Graham Av/Cook St", to: "Driggs Av/Leonard St"),
            "The B43 ride should resolve against the bus feed"
        )
        XCTAssertGreaterThan(stops.count, 3, "Expected the intermediate bus stops")
        XCTAssertEqual(stops.last?.stop.name.uppercased(), "DRIGGS AV/LEONARD ST")
        let minutes = stops.map(\.minutesFromBoarding)
        XCTAssertEqual(minutes, minutes.sorted(), "Stop timings should increase along the ride")
    }

    func testUnknownLinesAndStopsReturnNilRatherThanGuessing() {
        XCTAssertNil(MTASubwayData.intermediateStops(line: "Q999", from: "Nowhere", to: "Elsewhere"))
        XCTAssertNil(MTASubwayData.intermediateStops(line: "J", from: "Nowhere St", to: "Fulton St"))
    }

    func testDirectionIsRespected() throws {
        // Reversing the trip must still resolve, using the opposite direction's pattern.
        let stops = try XCTUnwrap(MTASubwayData.intermediateStops(line: "J", from: "Fulton St", to: "Flushing Av"))
        XCTAssertEqual(stops.last?.stop.name, "Flushing Av")
    }
}

