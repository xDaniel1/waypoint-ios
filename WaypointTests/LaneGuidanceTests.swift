import CoreLocation
import XCTest
@testable import Waypoint

/// Lane guidance is the one piece of navigation UI that can actively send someone into the wrong
/// lane, so the two places it can go wrong — reading OSM's lane syntax, and picking which road at
/// a junction the arrows belong to — are pinned down here rather than left to a test drive.
@MainActor
final class LaneGuidanceTests: XCTestCase {

    // MARK: Parsing OSM's turn:lanes syntax

    func testSplitsLanesAndMarksTheOnesServingTheTurn() {
        let lanes = LaneGuidanceService.parse("left|through|through;right", for: "TURN_RIGHT")

        XCTAssertEqual(lanes.count, 3)
        XCTAssertEqual(lanes.map(\.isRecommended), [false, false, true])
        XCTAssertEqual(lanes[2].indications, [.through, .right])
    }

    func testStraightAheadUsesThroughLanes() {
        let lanes = LaneGuidanceService.parse("left|through|through;right", for: nil)

        XCTAssertEqual(lanes.map(\.isRecommended), [false, true, true])
    }

    func testUnmarkedLaneReadsAsThrough() {
        let lanes = LaneGuidanceService.parse("left||", for: nil)

        XCTAssertEqual(lanes.count, 3)
        XCTAssertEqual(lanes.map(\.isRecommended), [false, true, true])
    }

    func testAPlainLeftLaneAlsoServesASharpLeft() {
        let lanes = LaneGuidanceService.parse("left|through", for: "TURN_SHARP_LEFT")

        XCTAssertEqual(lanes.map(\.isRecommended), [true, false])
    }

    /// A strip with nothing highlighted asks the driver a question instead of answering one, so
    /// paint that doesn't describe this turn is dropped entirely.
    func testDropsLanesWhenNothingServesTheTurn() {
        XCTAssertTrue(LaneGuidanceService.parse("through|through", for: "TURN_LEFT").isEmpty)
    }

    func testIgnoresImplausibleLaneCounts() {
        let tooMany = Array(repeating: "through", count: 14).joined(separator: "|")
        XCTAssertTrue(LaneGuidanceService.parse(tooMany, for: nil).isEmpty)
    }

    // MARK: Picking the road at the junction

    /// A north-south approach and an east-west cross street both sit within metres of the same
    /// junction, and the cross street is just as likely to be tagged. Its arrows on the banner
    /// would be a wrong instruction, not a missing one.
    func testIgnoresTheCrossStreetAtAJunction() {
        let junction = CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9500)
        let approach = way(
            tags: ["turn:lanes": "left|through", "oneway": "yes"],
            from: CLLocationCoordinate2D(latitude: 40.6980, longitude: -73.9500),
            to: junction
        )
        let crossStreet = way(
            tags: ["turn:lanes": "right|right", "oneway": "yes"],
            from: CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9520),
            to: junction
        )

        let value = LaneGuidanceService.approachLanes(
            in: [crossStreet, approach], at: junction, travelling: 0  // heading due north
        )

        XCTAssertEqual(value, "left|through")
    }

    /// Two-way street, tagged per direction: driving south has to read the backward lanes.
    func testReadsTheLanesForTheDirectionOfTravel() {
        let junction = CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9500)
        let street = way(
            tags: ["turn:lanes:forward": "through|right", "turn:lanes:backward": "left|through"],
            from: CLLocationCoordinate2D(latitude: 40.6980, longitude: -73.9500),
            to: CLLocationCoordinate2D(latitude: 40.7020, longitude: -73.9500)
        )

        let southbound = LaneGuidanceService.approachLanes(in: [street], at: junction, travelling: 180)
        let northbound = LaneGuidanceService.approachLanes(in: [street], at: junction, travelling: 0)

        XCTAssertEqual(southbound, "left|through")
        XCTAssertEqual(northbound, "through|right")
    }

    /// Without a heading there's no way to tell which side of a two-way street's paint applies,
    /// and a backwards lane strip is worse than none.
    func testSkipsATwoWayStreetWithNoHeading() {
        let junction = CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9500)
        let street = way(
            tags: ["turn:lanes:forward": "through|right", "turn:lanes:backward": "left|through"],
            from: CLLocationCoordinate2D(latitude: 40.6980, longitude: -73.9500),
            to: CLLocationCoordinate2D(latitude: 40.7020, longitude: -73.9500)
        )

        XCTAssertNil(LaneGuidanceService.approachLanes(in: [street], at: junction, travelling: nil))
    }

    // MARK: Maneuver classification

    /// MapKit gives no maneuver type at all, so the turn arrow comes from the shape of the route.
    func testClassifiesTurnsFromRouteGeometry() {
        let corner = CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9500)
        let fromSouth = [CLLocationCoordinate2D(latitude: 40.6990, longitude: -73.9500), corner]

        let east = [corner, CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9480)]
        let west = [corner, CLLocationCoordinate2D(latitude: 40.7000, longitude: -73.9520)]
        let onwards = [corner, CLLocationCoordinate2D(latitude: 40.7015, longitude: -73.9500)]
        let back = [corner, CLLocationCoordinate2D(latitude: 40.6985, longitude: -73.9501)]

        XCTAssertEqual(AppleRoutesService.maneuver(approaching: fromSouth, leaving: east), "TURN_RIGHT")
        XCTAssertEqual(AppleRoutesService.maneuver(approaching: fromSouth, leaving: west), "TURN_LEFT")
        // A road that just carries on isn't a maneuver, and Apple shows the straight arrow for it.
        XCTAssertNil(AppleRoutesService.maneuver(approaching: fromSouth, leaving: onwards))
        XCTAssertEqual(AppleRoutesService.maneuver(approaching: fromSouth, leaving: back), "UTURN_LEFT")
    }

    // MARK: Helpers

    private func way(
        tags: [String: String],
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> LaneGuidanceService.OverpassResponse.Element {
        let json = """
        {
          "tags": \(jsonObject(tags)),
          "geometry": [
            {"lat": \(from.latitude), "lon": \(from.longitude)},
            {"lat": \(to.latitude), "lon": \(to.longitude)}
          ]
        }
        """
        // Decoded rather than constructed so the tests exercise the same shape Overpass returns.
        return try! JSONDecoder().decode(
            LaneGuidanceService.OverpassResponse.Element.self, from: Data(json.utf8)
        )
    }

    private func jsonObject(_ tags: [String: String]) -> String {
        let pairs = tags.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
        return "{\(pairs)}"
    }
}
