import XCTest

/// Opens the real search sheet against the live MTA feeds and photographs the departures
/// section. The parsing is unit-tested against a hand-built feed; this is the other half —
/// whether the real feeds, the bundled station data and the layout agree in practice.
final class NearbyDeparturesDriveTests: XCTestCase {

    func testNearbyDeparturesAppearForABrooklynLocation() {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["Search Maps"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "search field never appeared")
        field.tap()

        // The feeds are a real network round trip on top of the first fix.
        let header = app.staticTexts["Nearby Departures"]
        let appeared = header.waitForExistence(timeout: 25)

        // Scroll the list rather than the sheet: swiping the sheet down collapses it and hides
        // the very rows this is meant to photograph.
        app.collectionViews.firstMatch.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = appeared ? "departures" : "no-departures"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(appeared, "No departures section — check simulator location is in NYC")
    }
}
