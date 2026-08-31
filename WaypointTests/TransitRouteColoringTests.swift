import CoreLocation
import SwiftUI
import XCTest
@testable import Waypoint

/// A J-to-A trip is the case that motivated this: the whole route used to draw in the first
/// ride's colour, so the A leg came out brown. The risk in the fix is index arithmetic — each
/// leg's coordinates reach one point back into the previous leg so the colours butt up
/// cleanly, and getting that offset wrong silently dims or brightens the wrong half of a leg.
@MainActor
final class TransitRouteColoringTests: XCTestCase {
    /// Walk to the J, ride the J, transfer, ride the A. Coordinates are a simple ascending
    /// ladder — what's under test is the splitting, not the geometry.
    private func jToATrip() -> RouteOption {
        func points(_ range: Range<Int>) -> [CLLocationCoordinate2D] {
            range.map { CLLocationCoordinate2D(latitude: 40.7 + Double($0) / 10_000, longitude: -73.9) }
        }

        // Leg boundaries along the whole route: walk 0..<10, J 10..<30, A 30..<50.
        let segments = [
            TransitSegment(
                coordinates: points(0..<10), range: 0..<10,
                isWalk: true, lineLabel: nil, providerColor: nil, isSubway: false
            ),
            TransitSegment(
                coordinates: points(9..<30), range: 10..<30,
                isWalk: false, lineLabel: "J", providerColor: nil, isSubway: true
            ),
            TransitSegment(
                coordinates: points(29..<50), range: 30..<50,
                isWalk: false, lineLabel: "A", providerColor: nil, isSubway: true
            ),
        ]

        var route = RouteOption(
            coordinates: points(0..<50),
            travelTime: 1800,
            distanceMeters: 5000,
            summary: "via J",
            transitSteps: []
        )
        route.transitSegments = segments
        return route
    }

    func testEachLegKeepsItsOwnLineColour() {
        let route = jToATrip()
        let colours = route.transitSegments.map(\.color)

        XCTAssertEqual(colours[1], MTASubwayLines.officialColor(forLine: "J"), "The J leg should draw in the MTA's J brown")
        XCTAssertEqual(colours[2], MTASubwayLines.officialColor(forLine: "A"), "The A leg should draw in the MTA's A blue")
        XCTAssertNotEqual(colours[1], colours[2], "A transfer has to be visible as a colour change")
    }

    func testRidingTheJLeavesTheATrainLegEntirelyAhead() throws {
        let navigation = NavigationViewModel()
        let route = jToATrip()
        navigation.start(route: route, destinationName: "Fulton St", destinationCoordinate: route.coordinates[49])
        // Twenty points in: halfway down the J.
        navigation.update(with: CLLocation(latitude: route.coordinates[20].latitude, longitude: route.coordinates[20].longitude))

        let pieces = navigation.drawableSegments
        let aTrainColour = try XCTUnwrap(MTASubwayLines.officialColor(forLine: "A"))
        let aTrainPieces = pieces.filter { $0.color == aTrainColour }

        XCTAssertFalse(aTrainPieces.isEmpty, "The A leg should still be drawn")
        XCTAssertTrue(
            aTrainPieces.allSatisfy { !$0.isTraveled },
            "Nothing on the A is behind you while you're still on the J"
        )

        let walkPieces = pieces.filter { $0.strokeStyle.dash.isEmpty == false }
        XCTAssertTrue(
            walkPieces.allSatisfy(\.isTraveled),
            "The walk to the station is done once you're on the train"
        )
    }

    func testTheLegYoureOnIsSplitAtYourPosition() throws {
        let navigation = NavigationViewModel()
        let route = jToATrip()
        navigation.start(route: route, destinationName: "Fulton St", destinationCoordinate: route.coordinates[49])
        navigation.update(with: CLLocation(latitude: route.coordinates[20].latitude, longitude: route.coordinates[20].longitude))

        XCTAssertEqual(navigation.progressIndex, 20, "The nearest point to the fix is the one it was taken from")

        let jColour = MTASubwayLines.officialColor(forLine: "J")
        let jPieces = navigation.drawableSegments.filter { $0.color == jColour }
        XCTAssertEqual(jPieces.count, 2, "The leg you're riding splits into a done half and a remaining half")

        let done = try XCTUnwrap(jPieces.first { $0.isTraveled })
        let ahead = try XCTUnwrap(jPieces.first { !$0.isTraveled })
        // The J leg spans route points 10...29 and its own array starts one point early, at 9.
        // Standing on point 20 puts the split at local index 11.
        XCTAssertEqual(done.coordinates.count, 12, "Points 9 through 20 inclusive are behind you")
        XCTAssertEqual(ahead.coordinates.count, 10, "Points 20 through 29 inclusive are still ahead")
    }

    func testADriveStillDrawsAsOneBlueLineSplitInTwo() {
        let navigation = NavigationViewModel()
        let coordinates = (0..<40).map {
            CLLocationCoordinate2D(latitude: 40.7 + Double($0) / 10_000, longitude: -73.9)
        }
        let route = RouteOption(
            coordinates: coordinates, travelTime: 600, distanceMeters: 2000,
            summary: "I-278", transitSteps: []
        )
        navigation.start(route: route, destinationName: "Home", destinationCoordinate: coordinates[39])
        navigation.update(with: CLLocation(latitude: coordinates[15].latitude, longitude: coordinates[15].longitude))

        let pieces = navigation.drawableSegments
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.color == .blue }, "A drive has no line colours to honour")
        XCTAssertEqual(pieces.filter(\.isTraveled).count, 1)
    }

    /// The distance-to-end table replaced a full walk of the remaining polyline on every fix;
    /// it has to produce the same number.
    func testRemainingDistanceShrinksAsYouGo() {
        let navigation = NavigationViewModel()
        let coordinates = (0..<40).map {
            CLLocationCoordinate2D(latitude: 40.7 + Double($0) / 10_000, longitude: -73.9)
        }
        let route = RouteOption(
            coordinates: coordinates, travelTime: 600, distanceMeters: 2000,
            summary: "I-278", transitSteps: []
        )
        navigation.start(route: route, destinationName: "Home", destinationCoordinate: coordinates[39])

        navigation.update(with: CLLocation(latitude: coordinates[5].latitude, longitude: coordinates[5].longitude))
        let early = navigation.remainingDistance
        navigation.update(with: CLLocation(latitude: coordinates[30].latitude, longitude: coordinates[30].longitude))
        let late = navigation.remainingDistance

        XCTAssertGreaterThan(early, late)
        // 35 points of ~11.1m each from index 5 to the end; a wide band, since the exact figure
        // depends on the map projection rather than on anything this test controls.
        XCTAssertEqual(early, 380, accuracy: 60)
        XCTAssertEqual(late, 100, accuracy: 40)
    }
}
