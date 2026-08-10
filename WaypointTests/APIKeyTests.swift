import XCTest
@testable import Waypoint

final class APIKeyTests: XCTestCase {
    func testAPIKeyExists() {
        let key = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String
        print("API_KEY_AT_RUNTIME: '\(key ?? "nil")'")
    }
}
