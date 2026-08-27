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
actor DiskCache<Value: Codable> {
    private struct Entry: Codable {
        let value: Value
        let cachedAt: Date
    }

    private let name: String
    private let ttl: TimeInterval
    private var memory: [String: Entry] = [:]
    private var loaded = false

    init(name: String, ttl: TimeInterval) {
        self.name = name
        self.ttl = ttl
    }

    func value(forKey key: String) -> Value? {
        loadIfNeeded()
        guard let entry = memory[key], isFresh(entry) else { return nil }
        return entry.value
    }

    func store(_ value: Value, forKey key: String) {
        loadIfNeeded()
        memory[key] = Entry(value: value, cachedAt: Date())
        persist()
    }

    private func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.cachedAt) < ttl
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
        // Drop anything already expired so the file doesn't grow without bound.
        memory = decoded.filter { isFresh($0.value) }
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
