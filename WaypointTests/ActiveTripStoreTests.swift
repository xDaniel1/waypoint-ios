import CoreLocation
import XCTest
@testable import Waypoint

/// The trip on disk is what a driver gets back after the app dies mid-drive, so it has to survive
/// the round trip intact — and it has to refuse to hand back something too old to still be the
/// trip anyone is on.
@MainActor
final class ActiveTripStoreTests: XCTestCase {
    private let store = ActiveTripStore.shared

    override func setUp() {
        super.setUp()
        store.clear()
    }

    override func tearDown() {
        store.clear()
        super.tearDown()
    }

    func testSavesAndRestoresATrip() throws {
        let route = drivingRoute()
        store.save(
            route: route,
            destinationName: "Prospect Park",
            destinationCoordinate: CLLocationCoordinate2D(latitude: 40.6602, longitude: -73.9690),
            stops: [CLLocationCoordinate2D(latitude: 40.6800, longitude: -73.9600)],
            force: true
        )

        let restored = try XCTUnwrap(store.resumableTrip())

        XCTAssertEqual(restored.destinationName, "Prospect Park")
        XCTAssertEqual(restored.stops.count, 1)
        XCTAssertEqual(restored.coordinates.count, route.coordinates.count)
        XCTAssertEqual(restored.route.steps.map(\.instruction), route.steps.map(\.instruction))
        XCTAssertEqual(restored.route.distanceMeters, route.distanceMeters)
        // The maneuver survives, which is what the banner's turn arrow is drawn from.
        XCTAssertEqual(restored.route.steps.first?.maneuver, "TURN_LEFT")
    }

    func testClearingRemovesTheTrip() {
        store.save(
            route: drivingRoute(),
            destinationName: "Prospect Park",
            destinationCoordinate: CLLocationCoordinate2D(latitude: 40.6602, longitude: -73.9690),
            stops: [],
            force: true
        )
        store.clear()

        XCTAssertNil(store.resumableTrip())
    }

    /// A transit itinerary's value is in departure times and live arrivals; handing one back
    /// twenty minutes later would put a rider on a train that's long gone.
    func testDoesNotSaveTransitTrips() {
        var route = drivingRoute()
        route.transitSegments = [
            TransitSegment(
                coordinates: route.coordinates,
                range: 0..<route.coordinates.count,
                isWalk: false,
                lineLabel: "J",
                providerColor: nil,
                isSubway: true
            )
        ]

        store.save(
            route: route,
            destinationName: "Broadway Junction",
            destinationCoordinate: CLLocationCoordinate2D(latitude: 40.6788, longitude: -73.9050),
            stops: [],
            force: true
        )

        XCTAssertNil(store.resumableTrip())
    }

    /// Without `force` a save is throttled, so the route isn't re-encoded on every GPS fix.
    func testThrottlesRepeatedSaves() throws {
        let first = drivingRoute()
        store.save(
            route: first, destinationName: "First",
            destinationCoordinate: CLLocationCoordinate2D(latitude: 40.66, longitude: -73.96),
            stops: [], force: true
        )
        store.save(
            route: first, destinationName: "Second",
            destinationCoordinate: CLLocationCoordinate2D(latitude: 40.66, longitude: -73.96),
            stops: []
        )

        XCTAssertEqual(try XCTUnwrap(store.resumableTrip()).destinationName, "First")
    }

    private func drivingRoute() -> RouteOption {
        let coordinates = (0..<10).map {
            CLLocationCoordinate2D(latitude: 40.700 + Double($0) * 0.001, longitude: -73.950)
        }
        return RouteOption(
            coordinates: coordinates,
            travelTime: 720,
            distanceMeters: 1_100,
            summary: "via Bushwick Ave",
            transitSteps: [],
            steps: [
                RouteStep(
                    instruction: "Turn left onto Bushwick Ave",
                    distanceMeters: 400,
                    startCoordinate: coordinates[0],
                    maneuver: "TURN_LEFT"
                ),
                RouteStep(
                    instruction: "Arrive at your destination",
                    distanceMeters: 0,
                    startCoordinate: coordinates.last,
                    maneuver: nil
                ),
            ]
        )
    }
}
