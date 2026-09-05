import CoreLocation
import XCTest
@testable import Waypoint

/// Text Search resolves a MapKit name + coordinate to a Google place ID by taking the first hit,
/// so these pin the guard that stops a common name from silently returning the wrong business.
final class PlaceMatchingTests: XCTestCase {

    private func place(named name: String, at coordinate: CLLocationCoordinate2D?) throws -> DetailedPlace {
        var fields: [String: Any] = ["id": "test", "displayName": ["text": name]]
        if let coordinate {
            fields["location"] = ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(DetailedPlace.self, from: data)
    }

    /// Roughly north by the given metres — enough to build a known separation.
    private func north(of origin: CLLocationCoordinate2D, metres: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + metres / 111_320, longitude: origin.longitude)
    }

    private let tapped = CLLocationCoordinate2D(latitude: 40.6782, longitude: -73.9442)

    func testSameSpotAndSameNameMatches() throws {
        let found = try place(named: "Joe's Pizza", at: north(of: tapped, metres: 20))
        XCTAssertTrue(GooglePlacesService.resolved(found, matches: "Joe's Pizza", near: tapped))
    }

    func testDifferentBranchOfTheSameChainIsRejected() throws {
        // The Starbucks four blocks away is a real Starbucks — just not the one that was tapped.
        let found = try place(named: "Starbucks", at: north(of: tapped, metres: 600))
        XCTAssertFalse(GooglePlacesService.resolved(found, matches: "Starbucks", near: tapped))
    }

    func testUnrelatedBusinessNextDoorIsRejected() throws {
        let found = try place(named: "Duane Reade", at: north(of: tapped, metres: 180))
        XCTAssertFalse(GooglePlacesService.resolved(found, matches: "Chase Bank", near: tapped))
    }

    /// Google and MapKit spell the same storefront differently all the time; on top of the
    /// coordinate that shouldn't count as a mismatch.
    func testNameSpeltDifferentlyStillMatchesWhenItIsRightThere() throws {
        let found = try place(named: "Dunkin'", at: north(of: tapped, metres: 30))
        XCTAssertTrue(GooglePlacesService.resolved(found, matches: "Dunkin Donuts", near: tapped))
    }

    /// A big venue's Google centroid can sit well off the entrance MapKit points at, so a clear
    /// name agreement has to be able to carry the match on its own.
    func testNameAgreementCarriesAMatchAcrossALargeVenue() throws {
        let found = try place(named: "Brooklyn Museum", at: north(of: tapped, metres: 200))
        XCTAssertTrue(GooglePlacesService.resolved(found, matches: "Brooklyn Museum", near: tapped))
    }

    func testPlaceWithNoCoordinateIsAccepted() throws {
        // Nothing to check against; rejecting here would lose a usable card for no reason.
        let found = try place(named: "Somewhere", at: nil)
        XCTAssertTrue(GooglePlacesService.resolved(found, matches: "Anything", near: tapped))
    }
}
