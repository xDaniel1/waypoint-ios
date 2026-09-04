import CarPlay
import XCTest
@testable import Waypoint

/// `Info.plist` names the CarPlay scene delegate as a *string*
/// (`$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`), so nothing checks it at compile time. Rename
/// or move the class and the car screen just silently never connects — there's no crash and no
/// warning, which is the single easiest way to break CarPlay without noticing.
final class CarPlaySceneTests: XCTestCase {
    private func sceneManifest() throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        // The tests run in their own bundle; the manifest lives in the app's.
        let appBundle = Bundle(identifier: "com.danielguzman.waypoint") ?? Bundle.main
        let manifest = (appBundle.object(forInfoDictionaryKey: "UIApplicationSceneManifest")
            ?? bundle.object(forInfoDictionaryKey: "UIApplicationSceneManifest")) as? [String: Any]
        return try XCTUnwrap(manifest, "Info.plist has no UIApplicationSceneManifest")
    }

    func testCarPlaySceneDelegateClassResolves() throws {
        let manifest = try sceneManifest()
        let configurations = try XCTUnwrap(manifest["UISceneConfigurations"] as? [String: Any])
        let carPlay = try XCTUnwrap(
            configurations["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]],
            "No CarPlay scene role declared"
        )
        let name = try XCTUnwrap(carPlay.first?["UISceneDelegateClassName"] as? String)

        XCTAssertNotNil(
            NSClassFromString(name),
            "Info.plist points at '\\(name)', which doesn't resolve to a class — CarPlay would never connect"
        )
        XCTAssertTrue(
            NSClassFromString(name) is CPTemplateApplicationSceneDelegate.Type,
            "'\\(name)' resolves but doesn't conform to CPTemplateApplicationSceneDelegate"
        )
    }

    /// The delegate is the one piece CarPlay instantiates itself, so it has to work with no
    /// arguments.
    func testCarPlaySceneDelegateIsConstructible() {
        XCTAssertNotNil(CarPlaySceneDelegate())
    }
}
