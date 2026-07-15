import Foundation
import Observation

@Observable
final class RecentSearchesStore {
    private(set) var recents: [RecentSearch] = []

    private let defaultsKey = "com.danielguzman.waypoint.recentSearches"
    private let maxCount = 10
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    func clear() {
        recents.removeAll()
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RecentSearch].self, from: data) else { return }
        recents = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
