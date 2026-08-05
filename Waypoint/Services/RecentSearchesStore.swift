import Foundation
import Observation

/// See `FavoritesStore`'s doc comment for why `NSUbiquitousKeyValueStore` and not `UserDefaults`,
/// and its last-write-wins-per-key sync caveat — same tradeoff applies here.
@Observable
final class RecentSearchesStore {
    private(set) var recents: [RecentSearch] = []

    private let defaultsKey = "com.danielguzman.waypoint.recentSearches"
    private let maxCount = 10
    private let store: KeyValueStore

    init(store: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        self.store = store
        load()
        if let ubiquitousStore = store as? NSUbiquitousKeyValueStore {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(externalChange),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: ubiquitousStore
            )
            ubiquitousStore.synchronize()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func externalChange() {
        load()
    }

    func add(_ result: SearchResult) {
        let entry = RecentSearch(
            id: UUID(),
            title: result.title,
            subtitle: result.subtitle,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            date: Date()
        )
        recents.removeAll { $0.title == entry.title && $0.subtitle == entry.subtitle }
        recents.insert(entry, at: 0)
        if recents.count > maxCount {
            recents.removeLast(recents.count - maxCount)
        }
        save()
    }

    func remove(_ recent: RecentSearch) {
        recents.removeAll { $0.id == recent.id }
        save()
    }

    func clear() {
        recents.removeAll()
        save()
    }

    private func load() {
        guard let data = store.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RecentSearch].self, from: data) else { return }
        recents = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        store.set(data, forKey: defaultsKey)
        (store as? NSUbiquitousKeyValueStore)?.synchronize()
    }
}
