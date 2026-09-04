import CoreLocation
import XCTest
@testable import Waypoint

/// The parts of a trip that get decided before any road is driven: which alternate to offer, what
/// order to visit stops in, and whether the route runs through something somebody reported.
@MainActor
final class RoutePlanningTests: XCTestCase {

    // MARK: Steering around reported incidents

    func testPutsTheRouteThatAvoidsTheIncidentFirst() {
        let through = route(from: 40.700, to: 40.710, longitude: -73.950)
        let clear = route(from: 40.700, to: 40.710, longitude: -73.990)
        let incident = CLLocationCoordinate2D(latitude: 40.705, longitude: -73.950)

        let ordered = AppleRoutesService.preferring([through, clear], avoiding: [incident])

        XCTAssertEqual(ordered.first?.id, clear.id)
        XCTAssertFalse(ordered[0].passesReportedIncident)
        XCTAssertTrue(ordered[1].passesReportedIncident)
    }

    /// When every way round goes through it, the fastest still wins — a route that quietly adds
    /// twenty minutes to dodge a cone is worse than being told there's a cone.
    func testKeepsTheFastestWhenEveryRoutePassesTheIncident() {
        let fastest = route(from: 40.700, to: 40.710, longitude: -73.950)
        let slower = route(from: 40.700, to: 40.710, longitude: -73.9501)
        let incident = CLLocationCoordinate2D(latitude: 40.705, longitude: -73.950)

        let ordered = AppleRoutesService.preferring([fastest, slower], avoiding: [incident])

        XCTAssertEqual(ordered.first?.id, fastest.id)
        XCTAssertTrue(ordered.allSatisfy(\.passesReportedIncident))
    }

    func testLeavesRoutesAloneWhenNothingHasBeenReported() {
        let a = route(from: 40.700, to: 40.710, longitude: -73.950)
        let b = route(from: 40.700, to: 40.710, longitude: -73.990)

        let ordered = AppleRoutesService.preferring([a, b], avoiding: [])

        XCTAssertEqual(ordered.map(\.id), [a.id, b.id])
    }

    /// Polylines put hundreds of metres between points on a straight, so a check against the
    /// vertices alone misses a blockage sitting squarely in the middle of one.
    func testDetectsAnIncidentBetweenTwoDistantPolylinePoints() {
        let straight = [
            CLLocationCoordinate2D(latitude: 40.700, longitude: -73.950),
            CLLocationCoordinate2D(latitude: 40.740, longitude: -73.950),
        ]
        let midway = CLLocationCoordinate2D(latitude: 40.720, longitude: -73.950)

        XCTAssertTrue(AppleRoutesService.passes(straight, within: 40, of: midway))
        XCTAssertFalse(
            AppleRoutesService.passes(
                straight, within: 40,
                of: CLLocationCoordinate2D(latitude: 40.720, longitude: -73.960)
            )
        )
    }

    // MARK: Stop order

    /// Stops typed in as A then B, where the road says B then A. The origin is next to B and the
    /// destination is next to A, so the order given doubles back on itself.
    func testFindsTheQuickerOrderForOutOfOrderStops() {
        //          origin  A    B   destination
        let matrix: [[TimeInterval]] = [
            [0, 600, 60, 660],   // origin -> A is a long way, -> B is next door
            [600, 0, 600, 60],   // A -> destination is next door
            [60, 600, 0, 660],
            [0, 0, 0, 0],        // nothing ever leaves the destination
        ]

        XCTAssertEqual(AppleRoutesService.bestOrder(stopCount: 2, matrix: matrix), [1, 0])
    }

    /// The order someone typed usually carries a reason the map can't see, so it's only overridden
    /// when there's real time in it.
    func testLeavesTheOrderAloneWhenTheSavingIsTrivial() {
        let matrix: [[TimeInterval]] = [
            [0, 300, 310, 600],
            [300, 0, 300, 300],
            [310, 300, 0, 290],
            [0, 0, 0, 0],
        ]

        XCTAssertNil(AppleRoutesService.bestOrder(stopCount: 2, matrix: matrix))
    }

    func testIgnoresASingleStop() {
        XCTAssertNil(AppleRoutesService.bestOrder(stopCount: 1, matrix: [[0, 1, 2], [1, 0, 1], [0, 0, 0]]))
    }

    /// Past six stops the exact search is swapped for nearest-neighbour plus 2-opt; it still has
    /// to find the obvious answer when the stops are strung out along a line.
    func testHandlesMoreStopsThanTheExactSearchCovers() {
        // Seven stops in a line, handed over back to front.
        let count = 7
        let positions = [0.0] + (1...count).map { Double(count + 1 - $0) } + [Double(count + 1)]
        var matrix = [[TimeInterval]](repeating: [TimeInterval](repeating: 0, count: count + 2), count: count + 2)
        for i in 0..<(count + 2) {
            for j in 0..<(count + 2) {
                matrix[i][j] = abs(positions[i] - positions[j]) * 600
            }
        }

        let order = AppleRoutesService.bestOrder(stopCount: count, matrix: matrix)

        // Reversed: the stop given last is nearest the origin.
        XCTAssertEqual(order, Array((0..<count).reversed()))
    }

    // MARK: Helpers

    private func route(from startLatitude: Double, to endLatitude: Double, longitude: Double) -> RouteOption {
        RouteOption(
            coordinates: stride(from: startLatitude, through: endLatitude, by: 0.001).map {
                CLLocationCoordinate2D(latitude: $0, longitude: longitude)
            },
            travelTime: 600,
            distanceMeters: 1_200,
            summary: "Route",
            transitSteps: []
        )
    }
}
