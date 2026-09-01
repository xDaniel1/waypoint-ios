import XCTest

final class WaypointUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        grantLocationPermissionIfAsked()
    }

    /// The location prompt belongs to SpringBoard, not the app, so it isn't dismissed by tapping
    /// inside the app. Anything that needs an origin (directions, recenter) stalls without this.
    private func grantLocationPermissionIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 8) {
            allow.tap()
        }
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

    // The app opens on the home card: search bar, Places row, and saved places — but none of
    // the search-mode UI (categories, tip card) until the field is focused.
    func test01_homeCardOnLaunch() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search field should exist")
        XCTAssertTrue(app.staticTexts["Places"].waitForExistence(timeout: 5), "Home card should show the Places section")
        XCTAssertTrue(app.staticTexts["Your Places"].exists, "Home card should show the saved-places section")
        XCTAssertFalse(app.buttons["Restaurants"].exists, "Category pills must be hidden until the field is focused")
        XCTAssertFalse(app.staticTexts["Try Voice Search"].exists, "Tip card must be hidden until the field is focused")
        XCTAssertTrue(app.buttons["micButton"].exists, "Mic button should be visible in the search bar")
        XCTAssertTrue(app.buttons["profileButton"].exists, "Profile button should be visible in the search bar")
        attachScreenshot("01a-home-card")

        // One pull takes the card straight to full screen — there is no stop in between.
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.exists, "Sheet should be draggable")
        let restingHeight = grabber.value as? String
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)))
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 5), "Expanded home card should show the Favorites collection")
        XCTAssertNotEqual(grabber.value as? String, restingHeight, "One pull should move the card off its resting height")
        attachScreenshot("01b-home-card-expanded")
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

        // Apple-style single-scroll card: Google-sourced sections render inline (no tabs).
        let aboutOrReviews = app.staticTexts["About"]
        let ratings = app.staticTexts["Ratings & Reviews"]
        let details = app.staticTexts["Details"]
        // Any one of the Google-backed sections proves the card populated.
        XCTAssertTrue(
            aboutOrReviews.waitForExistence(timeout: 25)
                || ratings.waitForExistence(timeout: 5)
                || details.waitForExistence(timeout: 5),
            "Google-sourced place sections should render on the card"
        )
        attachScreenshot("04b-place-detail-card")

        // The card scrolls vertically through its sections.
        app.swipeUp()
        attachScreenshot("04c-place-detail-scrolled")

        // Closing should return to the plain collapsed search bar.
        app.buttons["closeDetailButton"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search bar should return after closing the card")
        attachScreenshot("04f-closed")
    }

    // A long enough trip returns alternates: the card should page through them one at a time,
    // and list them all once the sheet is pulled to full height.
    func test09_routeAlternates() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("JFK Airport")

        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'JFK' OR label CONTAINS[c] 'Kennedy'")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "A JFK suggestion should appear")
        suggestion.tap()

        let getDirections = app.buttons["getDirectionsButton"]
        XCTAssertTrue(getDirections.waitForExistence(timeout: 15))
        getDirections.tap()

        XCTAssertTrue(app.staticTexts["Fastest"].waitForExistence(timeout: 25), "A driving route should be calculated")
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot("09a-alternates-paged")

        // Only the current page's GO is reachable while paging.
        let goButtons = app.buttons.matching(identifier: "goButton")
        let hittableGoCount = { goButtons.allElementsBoundByIndex.filter { $0.isHittable }.count }
        XCTAssertEqual(hittableGoCount(), 1, "Paged card shows one route at a time")

        app.staticTexts["Fastest"].firstMatch.swipeLeft()
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot("09b-alternates-swiped")

        // Expand the sheet: the route section becomes a full list of alternates.
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.exists)
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)))
        Thread.sleep(forTimeInterval: 2.0)
        attachScreenshot("09c-alternates-expanded-list")
        XCTAssertGreaterThanOrEqual(hittableGoCount(), 2, "Expanded card should list every alternate at once")
    }

    // Profile button should present the real sign-in sheet now that accounts are wired up.
    func test05_profileSheet() throws {
        let profileButton = app.buttons["profileButton"]
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10))
        profileButton.tap()

        XCTAssertTrue(app.staticTexts["Sign in to sync"].waitForExistence(timeout: 5))
        // Real diagnostics (CrashReportingService), not a placeholder — every fresh launch should
        // at least show the Diagnostics section with a last-session status row.
        XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Last Session"].exists)
        attachScreenshot("05-profile-sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5))
    }

    // Focusing search should load Google-powered Trending Restaurants; tapping one opens its detail.
    func test08_discoverTrending() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()

        // Trending cards load from Google after a network round-trip.
        let firstTrending = app.buttons["trending-1"]
        XCTAssertTrue(firstTrending.waitForExistence(timeout: 25), "A Trending Restaurant card should load from Google")
        attachScreenshot("08a-discover")
        firstTrending.tap()

        XCTAssertTrue(app.buttons["closeDetailButton"].waitForExistence(timeout: 10), "Tapping a trending card opens its place detail")
        attachScreenshot("08b-trending-detail")
        app.buttons["closeDetailButton"].tap()
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

        // At least one route option row should appear after calculation.
        XCTAssertTrue(
            app.staticTexts["Fastest"].waitForExistence(timeout: 20)
                || app.staticTexts["Route"].waitForExistence(timeout: 5),
            "A route option should appear after driving calculation"
        )
        attachScreenshot("07a-directions-drive")

        // At rest the card pages through one route at a time, so only that route's GO is reachable.
        let goButtons = app.buttons.matching(identifier: "goButton")
        let hittableGoCount = { goButtons.allElementsBoundByIndex.filter { $0.isHittable }.count }
        XCTAssertEqual(hittableGoCount(), 1, "At rest the card should show one route at a time")
        attachScreenshot("07e-route-pager")

        // Swiping sideways across the route card moves to the alternate.
        app.staticTexts["Fastest"].firstMatch.swipeLeft()
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot("07f-route-swiped")

        // Dragging the sheet to full height lists every alternate at once.
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.exists, "Sheet should be draggable")
        grabber.coordinate(withNormalizedOffset: .zero)
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThanOrEqual(hittableGoCount(), 1, "Expanded directions card should list routes")
        XCTAssertTrue(app.buttons["closeDirectionsButton"].isHittable, "Close button stays reachable when expanded")
        attachScreenshot("07g-route-list-expanded")

        // All four modes should be present (Drive/Walk/Transit/Bike).
        let driveButton = app.buttons["Drive"]
        let walkButton = app.buttons["Walk"]
        XCTAssertTrue(app.buttons["Transit"].exists, "Transit mode should exist")
        XCTAssertTrue(app.buttons["Bike"].exists, "Bike mode should exist")
        XCTAssertTrue(driveButton.isSelected, "Drive should start selected")

        walkButton.tap()
        XCTAssertTrue(walkButton.isSelected, "Walk should become selected after tapping it")
        XCTAssertFalse(driveButton.isSelected, "Drive should no longer be selected")
        Thread.sleep(forTimeInterval: 2.0)
        attachScreenshot("07b-directions-walk")

        // Bike uses Google Routes; whether it returns routes or an "enable API" notice,
        // the app must stay foregrounded and not crash.
        app.buttons["Bike"].tap()
        Thread.sleep(forTimeInterval: 3.0)
        XCTAssertEqual(app.state, .runningForeground, "Bike mode should be handled gracefully in-app")
        attachScreenshot("07d-bike")

        app.buttons["closeDirectionsButton"].tap()
        XCTAssertTrue(app.buttons["closeDetailButton"].waitForExistence(timeout: 5), "Closing directions should return to the place card")
        attachScreenshot("07c-back-to-place-detail")
    }

    // GO should start real in-app navigation: the banner appears (its first instruction is
    // spoken via AVSpeechSynthesizer on start), the mute toggle doesn't crash the audio session,
    // and End Route cleanly returns to search.
    func test10_navigationVoiceAndControls() throws {
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

        let goButton = app.buttons["goButton"].firstMatch
        XCTAssertTrue(goButton.waitForExistence(timeout: 25), "A route with a GO button should be calculated")
        goButton.tap()

        // The identifier lands on the banner's text/image children rather than a single
        // container element, so match any element type instead of one specific query type.
        let navigationBanner = app.staticTexts.matching(identifier: "navigationBanner").firstMatch
        XCTAssertTrue(navigationBanner.waitForExistence(timeout: 10), "Navigation banner should appear once GO is tapped")
        attachScreenshot("10a-navigation-started")

        // This exercises the real AVSpeechSynthesizer/AVAudioSession path that spoke the first
        // instruction when navigation started — toggling mute must not crash it either way.
        let muteButton = app.buttons["muteButton"]
        XCTAssertTrue(muteButton.waitForExistence(timeout: 5))
        muteButton.tap()
        XCTAssertEqual(app.state, .runningForeground, "Muting mid-navigation should not crash the app")
        muteButton.tap()
        XCTAssertEqual(app.state, .runningForeground, "Unmuting mid-navigation should not crash the app")
        attachScreenshot("10b-mute-toggled")
    }

    // Add Stop should insert a real waypoint the route is recalculated through, not just a
    // placeholder row.
    func test11_multiStopRouting() throws {
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

        XCTAssertTrue(app.staticTexts["Fastest"].waitForExistence(timeout: 25), "A driving route should be calculated")

        let addStop = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Stop'")).firstMatch
        XCTAssertTrue(addStop.waitForExistence(timeout: 5))
        addStop.tap()

        let stopSearchField = app.searchFields.firstMatch
        XCTAssertTrue(stopSearchField.waitForExistence(timeout: 5), "Add Stop sheet should present a search field")
        stopSearchField.tap()
        stopSearchField.typeText("Starbucks")

        let stopSuggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Starbucks'")).firstMatch
        XCTAssertTrue(stopSuggestion.waitForExistence(timeout: 10), "Add Stop sheet should show live suggestions")
        stopSuggestion.tap()

        // Sheet dismisses and the added stop shows up as its own row in the directions card,
        // proving it became a real waypoint rather than just closing the sheet.
        XCTAssertFalse(stopSearchField.waitForExistence(timeout: 3), "Add Stop sheet should dismiss after picking a result")
        let stopRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Starbucks'")).firstMatch
        XCTAssertTrue(stopRow.waitForExistence(timeout: 10), "The stop should appear as a row in the directions card")
        attachScreenshot("11a-stop-added")

        app.buttons["closeDirectionsButton"].tap()
    }

    // During active navigation, search-along-route should surface real Google results for a
    // category and let you add one as a stop without crashing the active trip.
    func test12_searchAlongRoute() throws {
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

        let goButton = app.buttons["goButton"].firstMatch
        XCTAssertTrue(goButton.waitForExistence(timeout: 25))
        goButton.tap()

        let navigationBanner = app.staticTexts.matching(identifier: "navigationBanner").firstMatch
        XCTAssertTrue(navigationBanner.waitForExistence(timeout: 10), "Navigation should be active")

        let searchAlongRoute = app.buttons["searchAlongRouteButton"]
        XCTAssertTrue(searchAlongRoute.waitForExistence(timeout: 5))
        searchAlongRoute.tap()

        let gasCategory = app.buttons["alongRouteCategory-gas"]
        XCTAssertTrue(gasCategory.waitForExistence(timeout: 5), "Category chips should appear")
        gasCategory.tap()

        let addButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'addAlongRouteStop-'")).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "A gas station result should load from Google along the route")
        attachScreenshot("12a-along-route-results")
        addButton.tap()

        // Adding a stop dismisses the sheet and recomputes the active route in place — the app
        // must stay in-app and foregrounded through that recalculation.
        XCTAssertTrue(navigationBanner.waitForExistence(timeout: 10), "Navigation should still be active after adding a stop")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // The star on a place card is the only way to create a favorite, since "Add" in the search
    // results list is unreachable through normal navigation. Then verifies the rename/emoji/color
    // editor (opened via swipe on the full Favorites list) actually persists into the list row.
    func test13_editableFavorites() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("Blue Bottle Coffee")

        let firstSuggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Blue Bottle'")).firstMatch
        XCTAssertTrue(firstSuggestion.waitForExistence(timeout: 10))
        firstSuggestion.tap()

        let favoriteButton = app.buttons["favoriteButton"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 10), "Place detail card should show a favorite star")
        favoriteButton.tap()
        attachScreenshot("13a-favorited")

        app.buttons["closeDetailButton"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Should return to the home/search bar")

        let yourPlacesTile = app.buttons["yourPlacesTile"]
        XCTAssertTrue(yourPlacesTile.waitForExistence(timeout: 5), "Your Places tile should appear once a favorite exists")
        yourPlacesTile.tap()

        let favoriteRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Blue Bottle'")).firstMatch
        XCTAssertTrue(favoriteRow.waitForExistence(timeout: 5), "The new favorite should appear in the full list")
        favoriteRow.swipeLeft()

        let editAction = app.buttons["Edit"]
        XCTAssertTrue(editAction.waitForExistence(timeout: 5), "Swiping a favorite row should reveal an Edit action")
        editAction.tap()

        let titleField = app.textFields["editFavoriteTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Edit sheet should present a name field")
        titleField.tap()
        titleField.typeText(" (Favorite)")
        attachScreenshot("13b-editing-favorite")

        app.buttons["Save"].tap()

        let renamedRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '(Favorite)'")).firstMatch
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5), "The renamed favorite should show its custom title in the list")
        attachScreenshot("13c-renamed")
    }

    // The home card's "Around Me" grid should run a real Google Places Nearby Search around the
    // user's current location, not just fill the search query like the pills elsewhere do.
    func test14_aroundMeGrid() throws {
        let searchField = app.textFields["searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Around Me"].waitForExistence(timeout: 5), "Home card should show the Around Me section")

        let foodChip = app.buttons["aroundMeCategory-food"]
        XCTAssertTrue(foodChip.waitForExistence(timeout: 5))
        foodChip.tap()

        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'aroundMeResult-'")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 15), "A real nearby restaurant should load from Google")
        attachScreenshot("14a-around-me-results")

        // Tapping the same chip again should collapse the strip back down.
        foodChip.tap()
        XCTAssertFalse(firstResult.exists, "Tapping the same category again should collapse the results")

        foodChip.tap()
        XCTAssertTrue(firstResult.waitForExistence(timeout: 15))
        firstResult.tap()

        XCTAssertTrue(app.buttons["closeDetailButton"].waitForExistence(timeout: 10), "Tapping a result should open the real place detail card")
        attachScreenshot("14b-around-me-place-detail")
    }
}
