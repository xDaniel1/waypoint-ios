import XCTest
@testable import Waypoint

/// The app shipped a launch crash for anyone who followed its own setup instructions: an
/// xcconfig file eats everything after `//`, so the documented
/// `SUPABASE_URL = https://ref.supabase.co` reached the app as the bare string `https:`, and
/// supabase-swift answers a URL with no host by trapping. These are the shapes that value can
/// realistically arrive in.
final class SupabaseConfigTests: XCTestCase {
    func testTheShapeXcconfigActuallyProducesIsRejected() {
        // What the build really put in Info.plist. Scheme, no host.
        XCTAssertNil(SupabaseBackend.projectURL(from: "https:"))
        XCTAssertNil(SupabaseBackend.projectURL(from: "https://"))
    }

    func testABareHostIsWhatTheTemplateNowAsksFor() {
        let url = SupabaseBackend.projectURL(from: "abcdefgh.supabase.co")
        XCTAssertEqual(url?.absoluteString, "https://abcdefgh.supabase.co")
        XCTAssertNotNil(url?.host())
    }

    func testPastingTheFullURLStillWorks() {
        XCTAssertEqual(
            SupabaseBackend.projectURL(from: "https://abcdefgh.supabase.co")?.absoluteString,
            "https://abcdefgh.supabase.co"
        )
        XCTAssertEqual(
            SupabaseBackend.projectURL(from: "  https://abcdefgh.supabase.co/  ")?.absoluteString,
            "https://abcdefgh.supabase.co"
        )
    }

    func testPlaceholdersAndUnsubstitutedVariablesDisableSyncRatherThanCrashing() {
        XCTAssertNil(SupabaseBackend.projectURL(from: ""))
        XCTAssertNil(SupabaseBackend.projectURL(from: "   "))
        XCTAssertNil(SupabaseBackend.projectURL(from: "$(SUPABASE_URL)"))
        XCTAssertNil(SupabaseBackend.projectURL(from: "YOUR_PROJECT_REF"))
        XCTAssertNil(SupabaseBackend.projectURL(from: "not a host.supabase.co"))
    }
}
