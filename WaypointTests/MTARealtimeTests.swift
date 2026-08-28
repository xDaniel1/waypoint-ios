import XCTest
@testable import Waypoint

/// A hand-rolled protobuf decoder is the kind of thing that silently returns nothing rather than
/// failing loudly, so these run against the live MTA feed and assert real trains come back.
@MainActor
final class MTARealtimeTests: XCTestCase {
    func testDecodesLiveDeparturesForTheJTrain() async throws {
        let service = MTARealtimeService()
        await service.load(line: "J", boardingStop: "Flushing Av", exitStop: "Fulton St")

        // The J runs 24/7, so there should always be an upcoming Manhattan-bound train.
        XCTAssertFalse(service.departures.isEmpty,
                       "Expected live J departures — an empty result means the protobuf walk failed")
        let minutes = service.departures.map(\.minutesAway)
        XCTAssertEqual(minutes, minutes.sorted(), "Departures should be in chronological order")
        XCTAssertTrue(minutes.allSatisfy { $0 < 120 }, "Departures should be soon, got \(minutes)")
    }

    func testUnknownLineYieldsNothingRatherThanGuessing() async {
        let service = MTARealtimeService()
        await service.load(line: "B43", boardingStop: "Graham Av/Cook St", exitStop: "Driggs Av")
        XCTAssertTrue(service.departures.isEmpty, "Buses aren't in the subway feeds")
    }

    func testProtobufReaderWalksNestedMessagesAndSkipsUnknownFields() {
        // field 1 (varint) = 150, field 2 (length-delimited) = "hi", field 1001 (varint) = 7,
        // mirroring MTA's NYCT extension field that must be skipped without breaking the walk.
        let data = Data([0x08, 0x96, 0x01, 0x12, 0x02, 0x68, 0x69, 0xC8, 0x3E, 0x07])
        var reader = ProtobufReader(data)

        guard let first = reader.nextField(), case .varint(let value) = first.value else {
            return XCTFail("Expected a varint field")
        }
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(value, 150)

        guard let second = reader.nextField(), case .bytes(let range) = second.value else {
            return XCTFail("Expected a length-delimited field")
        }
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(reader.string(range), "hi")

        guard let third = reader.nextField() else { return XCTFail("Unknown field should still parse") }
        XCTAssertEqual(third.number, 1001)
        XCTAssertNil(reader.nextField(), "Reader should stop cleanly at the end")
    }
}
