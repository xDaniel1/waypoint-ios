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

    /// Fires after every local edit, including ones applied by `load()` from an external iCloud
    /// change — a sync coordinator listens here to push. Not fired by `applySynced`, since that
    /// data just came *from* the coordinator and re-pushing it would be a no-op round trip.
    var onChange: (() -> Void)?

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

    /// Applies a rename and/or custom emoji/color from the edit sheet. `title` empty or
    /// unchanged from the original clears the override rather than storing a redundant copy.
    func update(_ favorite: FavoritePlace, title: String, emoji: String?, colorHex: String?) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].customTitle = (trimmedTitle.isEmpty || trimmedTitle == favorites[index].title) ? nil : trimmedTitle
        favorites[index].emoji = emoji
        favorites[index].colorHex = colorHex
        save()
    }

    /// Applies a snapshot pulled from a sync backend, bypassing `save()` so it doesn't turn
    /// straight around and push right back to where it came from.
    func applySynced(_ synced: [FavoritePlace]) {
        favorites = synced
        writeToStore()
    }

    private func load() {
        guard let data = store.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([FavoritePlace].self, from: data) else { return }
        favorites = decoded
        SpotlightIndexer.index(favorites)
    }

    private func save() {
        writeToStore()
        onChange?()
    }

    private func writeToStore() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        store.set(data, forKey: defaultsKey)
        (store as? NSUbiquitousKeyValueStore)?.synchronize()
        // Keeps system search in step with adds, renames and deletions.
        SpotlightIndexer.index(favorites)
    }
}
