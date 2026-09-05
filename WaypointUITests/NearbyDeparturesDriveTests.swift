import XCTest

/// Nearby departures belongs to Transit, not to the general search page.
///
/// Both halves matter: showing it to everyone opening the app to look for lunch was the problem,
/// and it still has to actually appear for the person who switched the map to Transit. The
/// parsing is unit-tested against a hand-built feed; this is the other half — whether the real
/// feeds, the bundled station data and the layout agree in practice.
///
/// Needs location authorised and set somewhere in NYC:
///   xcrun simctl privacy booted grant location-always com.danielguzman.waypoint
///   xcrun simctl location booted set 40.6782,-73.9442
final class NearbyDeparturesDriveTests: XCTestCase {

    private func openSearch(_ app: XCUIApplication) {
        let field = app.textFields["Search Maps"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "search field never appeared")
        field.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testDeparturesStayOutOfTheWayUntilTheMapIsInTransit() {
        let app = XCUIApplication()
        app.launch()
        openSearch(app)

        // Give the shelves time to populate, so this isn't just passing because nothing loaded.
        XCTAssertTrue(app.staticTexts["Recents"].waitForExistence(timeout: 25),
                      "search page never populated, so its absence proves nothing")
        capture(app, "explore-no-departures")
        XCTAssertFalse(app.staticTexts["Nearby Departures"].exists,
                       "Departures shouldn't be on the general search page")
    }

    func testDeparturesAppearOnceTheMapIsSwitchedToTransit() {
        let app = XCUIApplication()
        app.launch()

        let modes = app.buttons["mapModesButton"]
        XCTAssertTrue(modes.waitForExistence(timeout: 30), "map modes button never appeared")
        modes.tap()

        let transit = app.buttons["mapMode-transit"]
        XCTAssertTrue(transit.waitForExistence(timeout: 10), "transit mode never offered")
        transit.tap()

        openSearch(app)
        // A real network round trip to the MTA on top of the first fix.
        let appeared = app.staticTexts["Nearby Departures"].waitForExistence(timeout: 40)
        capture(app, appeared ? "transit-departures" : "transit-no-departures")
        XCTAssertTrue(appeared, "Transit mode should show what's leaving nearby")
    }
}
