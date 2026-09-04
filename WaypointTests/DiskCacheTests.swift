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
        // Writes are debounced to coalesce bursts, so durability is guaranteed as of a flush —
        // which is what the app does when it backgrounds.
        await writer.flush()

        let reader = DiskCache<[String]>(name: name, ttl: 3600)
        let value = await reader.value(forKey: "k")
        XCTAssertEqual(value, ["a", "b"], "Cache must survive a relaunch, not just the session")
    }

    func testExpiredEntriesAreNotReturned() async {
        let name = "test-\(UUID().uuidString)"
        let writer = DiskCache<[String]>(name: name, ttl: 3600)
        await writer.store(["stale"], forKey: "k")
        await writer.flush()

        // Same file, zero TTL — anything written is already expired.
        let reader = DiskCache<[String]>(name: name, ttl: 0)
        let value = await reader.value(forKey: "k")
        XCTAssertNil(value, "Expired entries must not be served")
    }

    /// The debounce must still land on its own, without anyone calling `flush()` — otherwise a
    /// session that never backgrounds cleanly would silently cache nothing to disk.
    func testDebouncedWriteLandsWithoutAnExplicitFlush() async throws {
        let name = "test-\(UUID().uuidString)"
        let writer = DiskCache<[String]>(name: name, ttl: 3600)
        await writer.store(["x"], forKey: "k")

        try await Task.sleep(for: .milliseconds(900))

        let reader = DiskCache<[String]>(name: name, ttl: 3600)
        let value = await reader.value(forKey: "k")
        XCTAssertEqual(value, ["x"], "A debounced write must still reach disk on its own")
    }

    /// A burst of stores must all survive — the debounce cancels the *pending write*, not the
    /// accumulated entries.
    func testBurstOfWritesAllSurvive() async {
        let name = "test-\(UUID().uuidString)"
        let writer = DiskCache<[String]>(name: name, ttl: 3600)
        for i in 0..<20 {
            await writer.store(["v\(i)"], forKey: "k\(i)")
        }
        await writer.flush()

        let reader = DiskCache<[String]>(name: name, ttl: 3600)
        for i in 0..<20 {
            let value = await reader.value(forKey: "k\(i)")
            XCTAssertEqual(value, ["v\(i)"], "Entry k\(i) was lost by write coalescing")
        }
    }

    func testMissingKeyReturnsNil() async {
        let cache = DiskCache<[String]>(name: "test-\(UUID().uuidString)", ttl: 3600)
        let value = await cache.value(forKey: "absent")
        XCTAssertNil(value)
    }
}
