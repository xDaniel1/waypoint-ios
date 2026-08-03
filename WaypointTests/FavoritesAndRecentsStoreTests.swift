import CoreLocation
import MapKit
import Testing
@testable import Waypoint

/// Stands in for `NSUbiquitousKeyValueStore` in tests — same `KeyValueStore` contract, no iCloud
/// account or entitlement needed to exercise the persistence/reload logic.
private final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Data] = [:]

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value as? Data
    }
}

private func makeResult(title: String, latitude: Double = 37.0, longitude: Double = -122.0) -> SearchResult {
    let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
    mapItem.name = title
    return SearchResult(mapItem: mapItem)
}

struct FavoritesStoreTests {
    @Test func toggleAddsAndPersistsAcrossInstances() {
        let backing = InMemoryKeyValueStore()
        let store = FavoritesStore(store: backing)
        store.toggle(makeResult(title: "Blue Bottle Coffee"))
        #expect(store.favorites.count == 1)

        // A second store instance sharing the same backing store (as two devices would via
        // iCloud) should pick up what the first one wrote.
        let reloaded = FavoritesStore(store: backing)
        #expect(reloaded.favorites.map(\.title) == ["Blue Bottle Coffee"])
    }

    @Test func toggleTwiceRemoves() {
        let store = FavoritesStore(store: InMemoryKeyValueStore())
        let result = makeResult(title: "Tartine Bakery")
        store.toggle(result)
        store.toggle(result)
        #expect(store.favorites.isEmpty)
    }

    @Test func remove() throws {
        let store = FavoritesStore(store: InMemoryKeyValueStore())
        store.toggle(makeResult(title: "Tartine Bakery"))
        let favorite = try #require(store.favorites.first)
        store.remove(favorite)
        #expect(store.favorites.isEmpty)
    }
}

struct RecentSearchesStoreTests {
    @Test func addPersistsAcrossInstances() {
        let backing = InMemoryKeyValueStore()
        let store = RecentSearchesStore(store: backing)
        store.add(makeResult(title: "Golden Gate Park"))

        let reloaded = RecentSearchesStore(store: backing)
        #expect(reloaded.recents.map(\.title) == ["Golden Gate Park"])
    }

    @Test func capsAtTenMostRecentFirst() {
        let store = RecentSearchesStore(store: InMemoryKeyValueStore())
        for i in 0..<12 {
            store.add(makeResult(title: "Place \(i)"))
        }
        #expect(store.recents.count == 10)
        #expect(store.recents.first?.title == "Place 11")
    }

    @Test func reAddingMovesToFrontWithoutDuplicating() {
        let store = RecentSearchesStore(store: InMemoryKeyValueStore())
        store.add(makeResult(title: "A"))
        store.add(makeResult(title: "B"))
        store.add(makeResult(title: "A"))
        #expect(store.recents.map(\.title) == ["A", "B"])
    }
}
