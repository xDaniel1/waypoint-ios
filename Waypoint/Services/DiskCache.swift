import Foundation
import OSLog

/// A TTL'd, disk-backed cache for billed Google responses.
///
/// Every cache in this app used to be in-memory only, which meant a cold launch re-billed
/// everything: 2 discover searches + 5 guide shelves + 6 city guides = 13 Nearby Search calls
/// before the user had touched anything, plus a photo request per card. Persisting to disk turns
/// a relaunch into zero calls until the TTL genuinely expires.
///
/// Lives in `Caches/` deliberately — this is all re-fetchable, so the system is free to evict it
/// under storage pressure rather than us holding space the user can't reclaim.
/// How long past its TTL an entry is still worth holding on to for the offline case. It has to
/// stop somewhere or the file grows forever; a month is far longer than any plausible stretch
/// without signal, and this all lives in `Caches/` so the system can evict it anyway.
private let diskCacheStaleFloor: TimeInterval = 30 * 24 * 3600

actor DiskCache<Value: Codable> {
    private struct Entry: Codable {
        let value: Value
        let cachedAt: Date
    }

    private let name: String
    private let ttl: TimeInterval
    private var memory: [String: Entry] = [:]
    private var loaded = false
    /// Coalesces writes — see `schedulePersist()`.
    private var pendingWrite: Task<Void, Never>?

    init(name: String, ttl: TimeInterval) {
        self.name = name
        self.ttl = ttl
        DiskCacheRegistry.register { [weak self] in await self?.flush() }
    }

    /// `allowingStale` is for the offline case, and only for it.
    ///
    /// Past the TTL a value isn't good enough to serve when we *could* refresh it. With no
    /// network there's nothing to refresh from, and this morning's copy of a place card beats an
    /// empty screen on a subway platform — nothing about a restaurant's address or photos goes
    /// wrong in a few hours. Callers pass the connectivity state; the cache doesn't reach for it
    /// itself, partly to stay testable and partly because `NetworkMonitor` is main-actor-bound
    /// and this is an actor.
    func value(forKey key: String, allowingStale: Bool = false) -> Value? {
        loadIfNeeded()
        guard let entry = memory[key] else { return nil }
        if isFresh(entry) { return entry.value }
        return allowingStale && isWorthKeeping(entry) ? entry.value : nil
    }

    func store(_ value: Value, forKey key: String) {
        loadIfNeeded()
        memory[key] = Entry(value: value, cachedAt: Date())
        schedulePersist()
    }

    /// Writing on every `store` meant re-encoding *the whole cache* and rewriting the whole file
    /// once per entry. Loading the search page stores ~13 nearby results back to back, so that
    /// was 13 full re-encodes of a growing file in a burst. Debouncing collapses a burst into one
    /// write without changing what ends up on disk — reads are served from `memory` regardless,
    /// so a slightly later write costs nothing.
    private func schedulePersist() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    /// Flushes any debounced write immediately — for app backgrounding, where the 500ms window
    /// might otherwise be cut short by suspension.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        persist()
    }

    private func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.cachedAt) < ttl
    }

    private func isWorthKeeping(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.cachedAt) < diskCacheStaleFloor
    }

    // MARK: Disk

    private var fileURL: URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("waypoint-cache-\(name).json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            // A schema change makes old entries undecodable; drop them rather than wedging
            // the cache permanently.
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        // Keep expired-but-recent entries: they're no longer fresh enough to serve while the
        // network is up, but they're what makes the app work at all without one. Dropping them
        // at the TTL meant a relaunch threw away every place card the user had already opened.
        memory = decoded.filter { isWorthKeeping($0.value) }
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(memory) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.places.error("Cache write failed for \(self.name): \(error.localizedDescription)")
        }
    }
}

/// Lets the app flush every cache's debounced write when it goes to the background.
///
/// `DiskCache` coalesces writes on a 500ms timer, which is invisible in normal use but could
/// otherwise lose the last write if the process is suspended inside that window.
enum DiskCacheRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var flushers: [@Sendable () async -> Void] = []

    static func register(_ flush: @escaping @Sendable () async -> Void) {
        lock.withLock { flushers.append(flush) }
    }

    static func flushAll() async {
        // The snapshot is taken synchronously and the awaits happen outside the lock — holding a
        // lock across a suspension point is what the compiler rejects, and rightly so.
        let all = lock.withLock { flushers }
        for flush in all { await flush() }
    }
}
