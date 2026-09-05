import XCTest

/// The location button's state machine, driven through the real app.
///
/// The glyph is the only thing telling you whether the map is following you, and three of the
/// four states are near-identical arrows, so a wrong one is invisible in review and obvious in
/// the hand. The accessibility label is the same state in words, which is what makes it
/// assertable here.
///
/// Needs location authorised on the simulator, or the app never gets a fix, never starts
/// following, and every assertion below reads as a failure when nothing is actually wrong:
///   xcrun simctl privacy <device> grant location-always com.danielguzman.waypoint
final class LocationButtonDriveTests: XCTestCase {

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheButtonCyclesFollowAndHeadingTheWayApplesDoes() {
        let app = XCUIApplication()
        app.launch()

        let button = app.buttons["locationButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "location button never appeared")

        // Apple opens already following you, not waiting to be asked. The wait is generous
        // because this is the first fix of a cold launch, not a state transition.
        let followingAtLaunch = button.waitForLabel("Following my location", timeout: 30)
        capture(app, followingAtLaunch ? "1-launch" : "launch-state-wrong")
        XCTAssertTrue(followingAtLaunch,
                      "Should open already following. Got \(button.label) — if that's "
                      + "\"Recenter on my location\", check location is authorised on the simulator.")

        // From following, the next tap adds heading; the one after drops back to plain follow.
        button.tap()
        XCTAssertTrue(button.waitForLabel("Following my location and heading"),
                      "Second state should turn the map to face the way you are")
        capture(app, "2-heading")

        button.tap()
        XCTAssertTrue(button.waitForLabel("Following my location"),
                      "Third tap should straighten back to plain follow")
        capture(app, "3-follow")
    }
}

private extension XCUIElement {
    /// `label` is not observable, so this polls rather than waiting on a KVO expectation.
    func waitForLabel(_ expected: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if label == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
