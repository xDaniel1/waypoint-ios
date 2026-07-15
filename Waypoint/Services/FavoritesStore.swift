import Foundation
import Observation

@Observable
final class FavoritesStore {
    private(set) var favorites: [FavoritePlace] = []

    private let defaultsKey = "com.danielguzman.waypoint.favorites"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([FavoritePlace].self, from: data) else { return }
        favorites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
