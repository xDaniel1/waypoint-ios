import XCTest
@testable import Waypoint

/// True offline *maps* aren't buildable on MapKit — it exposes no tile download to third-party
/// apps. What is buildable is everything either side of the map still working, and the biggest
/// piece of that is not throwing away data we already have just because it aged out.
final class OfflineCacheTests: XCTestCase {

    private func makeCache(ttl: TimeInterval) -> DiskCache<String> {
        // A unique name per test so the on-disk file from one can't leak into another.
        DiskCache<String>(name: "test-\(UUID().uuidString)", ttl: ttl)
    }

    func testFreshValuesComeBackWhetherOrNotStaleIsAllowed() async {
        let cache = makeCache(ttl: 60)
        await cache.store("Joe's Pizza", forKey: "joe")

        var value = await cache.value(forKey: "joe")
        XCTAssertEqual(value, "Joe's Pizza")
        value = await cache.value(forKey: "joe", allowingStale: true)
        XCTAssertEqual(value, "Joe's Pizza")
    }

    /// Online, an expired entry must not be served — we can refresh, so we should.
    func testExpiredValuesAreWithheldWhileWeCouldRefreshThem() async {
        let cache = makeCache(ttl: 0)
        await cache.store("Joe's Pizza", forKey: "joe")

        let value = await cache.value(forKey: "joe")
        XCTAssertNil(value, "With a network available, stale data should be refetched not reused")
    }

    /// Offline, the same entry is the whole point: it's this or an empty screen.
    func testExpiredValuesAreServedWhenThereIsNothingToRefreshFrom() async {
        let cache = makeCache(ttl: 0)
        await cache.store("Joe's Pizza", forKey: "joe")

        let value = await cache.value(forKey: "joe", allowingStale: true)
        XCTAssertEqual(value, "Joe's Pizza", "Offline, this morning's copy beats nothing")
    }

    func testAMissingKeyIsStillMissingWhenStaleIsAllowed() async {
        let cache = makeCache(ttl: 0)
        let value = await cache.value(forKey: "never-stored", allowingStale: true)
        XCTAssertNil(value)
    }

    /// The regression this was really about: relaunching used to filter expired entries out of
    /// the file as it loaded, so every place card you'd opened was gone by the next morning
    /// whether or not you had signal.
    func testExpiredEntriesSurviveARelaunchRatherThanBeingDeletedOnLoad() async {
        let name = "test-relaunch-\(UUID().uuidString)"
        let writer = DiskCache<String>(name: name, ttl: 0)
        await writer.store("Joe's Pizza", forKey: "joe")
        await writer.flush()

        // A second instance over the same file is what a cold launch actually does.
        let reader = DiskCache<String>(name: name, ttl: 0)
        let value = await reader.value(forKey: "joe", allowingStale: true)
        XCTAssertEqual(value, "Joe's Pizza", "A relaunch must not bin data we may need offline")
    }
}
