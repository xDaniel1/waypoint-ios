import XCTest

final class WaypointUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Collapsed sheet should show only the search bar — no categories, recents, or tip card.
    func test01_collapsedStateShowsOnlySearchBar() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search field should exist")
        XCTAssertFalse(app.buttons["Restaurants"].exists, "Category pills must be hidden until the field is focused")
        XCTAssertFalse(app.staticTexts["Try Voice Search"].exists, "Tip card must be hidden until the field is focused")
        XCTAssertTrue(app.buttons["micButton"].exists, "Mic button should be visible in the collapsed bar")
        XCTAssertTrue(app.buttons["profileButton"].exists, "Profile button should be visible in the collapsed bar")
        attachScreenshot("01-collapsed")
    }

    // Focusing the field should expand the sheet and reveal the browse sections.
    func test02_focusRevealsSections() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()

        XCTAssertTrue(app.buttons["Restaurants"].waitForExistence(timeout: 5), "Category pills should appear on focus")
        XCTAssertTrue(app.buttons["Coffee"].exists)
        XCTAssertTrue(app.buttons["Gas"].exists)
        attachScreenshot("02-focused-sections")
    }

    // Tapping a category pill should fill the query and produce live suggestions.
    func test03_categoryPillFillsQuery() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()

        let pill = app.buttons["Coffee"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        pill.tap()

        XCTAssertEqual(searchField.value as? String, "Coffee", "Category tap should fill the search field")
        attachScreenshot("03-category-query")
    }

    // Typing should produce live autocomplete suggestions; selecting one should open
    // the Google-Places-backed detail card in the same sheet.
    func test04_searchSelectAndPlaceDetail() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("Blue Bottle Coffee")

        // First row of live suggestions (buttons inside the list).
        let firstSuggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Blue Bottle'")).firstMatch
        XCTAssertTrue(firstSuggestion.waitForExistence(timeout: 10), "Live suggestions should appear for a typed query")
        attachScreenshot("04a-suggestions")
        firstSuggestion.tap()

        // Detail card: close button appears immediately; Google-sourced content within network timeout.
        XCTAssertTrue(app.buttons["closeDetailButton"].waitForExistence(timeout: 10), "Detail card should replace search UI")
        XCTAssertTrue(app.buttons["getDirectionsButton"].waitForExistence(timeout: 5))

        // Tabbed layout: Reviews/Photos/Menu chips appear once Google data loads.
        let reviewsTab = app.buttons["tab-Reviews"]
        XCTAssertTrue(reviewsTab.waitForExistence(timeout: 20), "Reviews tab should appear once Google data loads")
        attachScreenshot("04b-place-detail-overview")

        reviewsTab.tap()
        XCTAssertTrue(reviewsTab.isSelected, "Reviews tab should become selected")
        attachScreenshot("04c-reviews-tab")

        let photosTab = app.buttons["tab-Photos"]
        XCTAssertTrue(photosTab.waitForExistence(timeout: 5), "Photos tab should exist")
        photosTab.tap()
        attachScreenshot("04d-photos-tab")

        app.buttons["tab-Menu"].tap()
        attachScreenshot("04e-menu-tab")

        // Closing should return to the plain collapsed search bar.
        app.buttons["closeDetailButton"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search bar should return after closing the card")
        attachScreenshot("04f-closed")
    }

    // Profile button should present the honest accounts-not-built-yet sheet.
    func test05_profileSheet() throws {
        let profileButton = app.buttons["profileButton"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10))
        profileButton.tap()

        XCTAssertTrue(app.staticTexts["Accounts aren't built yet"].waitForExistence(timeout: 5))
        attachScreenshot("05-profile-sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
    }

    // Map style menu should offer Standard/Satellite/Hybrid and apply a selection.
    func test06_mapStyleMenu() throws {
        let styleButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'layer'")).firstMatch
        XCTAssertTrue(styleButton.waitForExistence(timeout: 10), "Map style menu button should exist")
        styleButton.tap()

        let satellite = app.buttons["Satellite"]
        XCTAssertTrue(satellite.waitForExistence(timeout: 5), "Style menu should list Satellite")
        satellite.tap()
        attachScreenshot("06-satellite-style")
    }

    // Get Directions should stay in-app: mode picker + route summary, never leaving to Apple Maps.
    func test07_inAppDirections() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("Blue Bottle Coffee")

        let firstSuggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Blue Bottle'")).firstMatch
        XCTAssertTrue(firstSuggestion.waitForExistence(timeout: 10))
        firstSuggestion.tap()

        let getDirections = app.buttons["getDirectionsButton"]
        XCTAssertTrue(getDirections.waitForExistence(timeout: 10))
        getDirections.tap()

        XCTAssertTrue(app.buttons["closeDirectionsButton"].waitForExistence(timeout: 5), "Directions card should appear")
        XCTAssertTrue(app.buttons["Drive"].waitForExistence(timeout: 5), "Mode picker should appear")
        // App must still be foregrounded — confirms we never handed off to Apple Maps.
        XCTAssertEqual(app.state, .runningForeground)

        XCTAssertTrue(
            app.otherElements["routeSummary"].waitForExistence(timeout: 15)
                || app.staticTexts.element(matching: NSPredicate(format: "label CONTAINS[c] %@", "route")).waitForExistence(timeout: 5),
            "Route summary or an error message should appear after calculation"
        )
        attachScreenshot("07a-directions-drive")

        let driveButton = app.buttons["Drive"]
        let walkButton = app.buttons["Walk"]
        XCTAssertTrue(walkButton.waitForExistence(timeout: 5), "Walk button should exist inside the mode picker")
        XCTAssertTrue(driveButton.isSelected, "Drive should start selected")
        walkButton.tap()
        XCTAssertTrue(walkButton.isSelected, "Walk should become selected after tapping it")
        XCTAssertFalse(driveButton.isSelected, "Drive should no longer be selected")
        // Let the walking route recalculate before capturing.
        Thread.sleep(forTimeInterval: 2.0)
        attachScreenshot("07b-directions-walk")

        app.buttons["closeDirectionsButton"].tap()
        XCTAssertTrue(app.buttons["closeDetailButton"].waitForExistence(timeout: 5), "Closing directions should return to the place card")
        attachScreenshot("07c-back-to-place-detail")
    }
}
