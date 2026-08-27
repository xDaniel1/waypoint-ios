import XCTest
@testable import Waypoint

/// The whole point of this cache is surviving a relaunch, so the test writes with one instance
/// and reads with a separate one — an in-memory-only cache passes a same-instance test and still
/// re-bills every call on the next launch, which is the bug this replaced.
final class DiskCacheTests: XCTestCase {
    func testValueSurvivesANewCacheInstance() async {
        let name = "test-\(UUID().uuidString)"
        let writer = DiskCache<[String]>(name: name, ttl: 3600)
        await writer.store(["a", "b"], forKey: "k")

        let reader = DiskCache<[String]>(name: name, ttl: 3600)
        let value = await reader.value(forKey: "k")
        XCTAssertEqual(value, ["a", "b"], "Cache must survive a relaunch, not just the session")
    }

    func testExpiredEntriesAreNotReturned() async {
        let name = "test-\(UUID().uuidString)"
        let writer = DiskCache<[String]>(name: name, ttl: 3600)
        await writer.store(["stale"], forKey: "k")

        // Same file, zero TTL — anything written is already expired.
        let reader = DiskCache<[String]>(name: name, ttl: 0)
        let value = await reader.value(forKey: "k")
        XCTAssertNil(value, "Expired entries must not be served")
    }

    func testMissingKeyReturnsNil() async {
        let cache = DiskCache<[String]>(name: "test-\(UUID().uuidString)", ttl: 3600)
        let value = await cache.value(forKey: "absent")
        XCTAssertNil(value)
    }
}
