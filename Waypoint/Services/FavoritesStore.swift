import Foundation
import Observation

/// Backed by `NSUbiquitousKeyValueStore` rather than `UserDefaults` so favorites show up on a
/// user's other devices — the whole list is well under its 1MB/1024-key ceiling, so one JSON
/// blob under one key is simpler than a CloudKit record per favorite. iCloud KV storage is
/// last-write-wins per key, not a per-item merge: if two devices edit favorites while offline,
/// whichever syncs second overwrites the other's changes to this list. Acceptable for a list
/// people edit from one phone at a time; a real merge would need CloudKit.
@Observable
final class FavoritesStore {
    private(set) var favorites: [FavoritePlace] = []

    private let defaultsKey = "com.danielguzman.waypoint.favorites"
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

    func isFavorite(_ result: SearchResult) -> Bool {
        favorites.contains { $0.title == result.title && $0.subtitle == result.subtitle }
    }

    func toggle(_ result: SearchResult) {
        if let index = favorites.firstIndex(where: { $0.title == result.title && $0.subtitle == result.subtitle }) {
            favorites.remove(at: index)
        } else {
            favorites.append(
                FavoritePlace(
                    id: UUID(),
                    title: result.title,
                    subtitle: result.subtitle,
                    latitude: result.coordinate.latitude,
                    longitude: result.coordinate.longitude
                )
            )
        }
        save()
    }

    func remove(_ favorite: FavoritePlace) {
        favorites.removeAll { $0.id == favorite.id }
        save()
    }

    private func load() {
        guard let data = store.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([FavoritePlace].self, from: data) else { return }
        favorites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        store.set(data, forKey: defaultsKey)
        (store as? NSUbiquitousKeyValueStore)?.synchronize()
    }
}
