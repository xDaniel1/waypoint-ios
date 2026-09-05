import CoreLocation
import XCTest
@testable import Waypoint

/// Nearby departures reads two things that can each be quietly wrong: which stations are within
/// walking distance (bundled GTFS) and what's due at them (a hand-walked protobuf). Both are
/// covered here without touching the network.
final class NearbyDeparturesTests: XCTestCase {

    // MARK: A GTFS-Realtime feed, built by hand

    /// Just enough protobuf to build a FeedMessage. Field numbers are from the GTFS-RT spec, the
    /// same ones `MTAFeed.parseDepartures` reads.
    private func varint(_ value: Int) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private func tag(_ field: Int, _ wire: Int) -> [UInt8] { varint(field << 3 | wire) }
    private func lengthDelimited(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(payload.count) + payload
    }
    private func string(_ field: Int, _ value: String) -> [UInt8] {
        lengthDelimited(field, Array(value.utf8))
    }
    private func varintField(_ field: Int, _ value: Int) -> [UInt8] { tag(field, 0) + varint(value) }

    /// One trip on `route`, calling at `stopID` at `time`.
    private func feed(route: String, stopID: String, at time: Date) -> Data {
        let trip = string(5, route)
        let departureEvent = varintField(2, Int(time.timeIntervalSince1970))
        let stopTimeUpdate = string(4, stopID) + lengthDelimited(3, departureEvent)
        let tripUpdate = lengthDelimited(1, trip) + lengthDelimited(2, stopTimeUpdate)
        let entity = lengthDelimited(3, tripUpdate)
        return Data(lengthDelimited(2, entity))
    }

    func testReadsTheLineStationDirectionAndTimeOutOfAFeed() {
        let now = Date()
        let due = now.addingTimeInterval(240)
        // "A41N" — station A41, northbound platform.
        let parsed = MTAFeed.parseDepartures(
            feed(route: "A", stopID: "A41N", at: due), stationIDs: ["A41"], now: now
        )

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.routeID, "A")
        XCTAssertEqual(parsed.first?.stationID, "A41", "The platform suffix isn't part of the station")
        XCTAssertEqual(parsed.first?.isUptown, true)
        XCTAssertEqual(parsed.first?.time.timeIntervalSince1970 ?? 0,
                       due.timeIntervalSince1970, accuracy: 1)
    }

    func testSouthboundPlatformsReadAsDowntown() {
        let now = Date()
        let parsed = MTAFeed.parseDepartures(
            feed(route: "A", stopID: "A41S", at: now.addingTimeInterval(120)),
            stationIDs: ["A41"], now: now
        )
        XCTAssertEqual(parsed.first?.isUptown, false)
    }

    /// A train that already left is on the platform sign for nobody.
    func testTrainsAlreadyGoneAreDropped() {
        let now = Date()
        let parsed = MTAFeed.parseDepartures(
            feed(route: "A", stopID: "A41N", at: now.addingTimeInterval(-300)),
            stationIDs: ["A41"], now: now
        )
        XCTAssertTrue(parsed.isEmpty)
    }

    func testStationsWeDidNotAskAboutAreIgnored() {
        let now = Date()
        let parsed = MTAFeed.parseDepartures(
            feed(route: "A", stopID: "A41N", at: now.addingTimeInterval(240)),
            stationIDs: ["G22"], now: now
        )
        XCTAssertTrue(parsed.isEmpty)
    }

    func testRubbishIsNotMistakenForAFeed() {
        XCTAssertTrue(MTAFeed.parseDepartures(Data("not a protobuf".utf8),
                                              stationIDs: ["A41"], now: Date()).isEmpty)
    }

    // MARK: Which stations are nearby

    @MainActor
    func testFindsRealStationsNearAtlanticAvenue() {
        // Atlantic Av–Barclays Ctr, one of the busiest interchanges in Brooklyn.
        let stations = MTASubwayData.stations(
            near: CLLocationCoordinate2D(latitude: 40.6840, longitude: -73.9770), within: 500
        )
        XCTAssertFalse(stations.isEmpty, "Expected subway stations beside Barclays Center")
        XCTAssertEqual(stations, stations.sorted { $0.metresAway < $1.metresAway },
                       "Nearest first — that's the walking decision")
        XCTAssertTrue(stations.allSatisfy { $0.metresAway <= 500 })
        // An interchange should come back as one station carrying several lines, not one row
        // per line.
        XCTAssertTrue(stations.contains { $0.lines.count > 1 },
                      "Atlantic Av is served by more than one line")
    }

    @MainActor
    func testSomewhereWithNoSubwayReturnsNothingRatherThanReachingForTheNearestOne() {
        // Kansas. The section hides rather than showing a station 1,800km away.
        let stations = MTASubwayData.stations(
            near: CLLocationCoordinate2D(latitude: 39.0, longitude: -98.0)
        )
        XCTAssertTrue(stations.isEmpty)
    }

    @MainActor
    func testBusStopsAreNotOfferedSinceTheirLiveTimesComeFromADifferentSystem() {
        let stations = MTASubwayData.stations(
            near: CLLocationCoordinate2D(latitude: 40.6840, longitude: -73.9770), within: 500
        )
        XCTAssertTrue(stations.allSatisfy { $0.lines.allSatisfy(MTASubwayData.isSubway) })
    }
}
