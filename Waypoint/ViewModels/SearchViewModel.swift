import MapKit
import Observation
import SwiftUI

@Observable
@MainActor
final class SearchViewModel {
    var queryText: String = "" {
        didSet { completerService.updateQuery(queryText) }
    }

    private(set) var selectedResult: SearchResult?
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    var suggestions: [MKLocalSearchCompletion] {
        completerService.suggestions
    }

    let recentsStore = RecentSearchesStore()
    let favoritesStore = FavoritesStore()
    let speechService = SpeechRecognitionService()
    let nearbyService = NearbyPlacesService()
    let discover = DiscoverViewModel()
    let syncCoordinator: SyncCoordinator

    private let completerService = SearchCompleterService()
    private var lastRegionCenter: CLLocationCoordinate2D?

    // Explicit so `syncCoordinator` can wire itself into `favoritesStore`/`recentsStore` after
    // their own (default-valued) initializers have already run.
    init() {
        syncCoordinator = SyncCoordinator(favoritesStore: favoritesStore, recentsStore: recentsStore)
    }

    func updateSearchRegion(_ region: MKCoordinateRegion) {
        completerService.updateRegion(region)
        lastRegionCenter = region.center
        Task { await nearbyService.refresh(around: region) }
    }

    func loadDiscover() {
        guard let center = lastRegionCenter else { return }
        Task { await discover.loadIfNeeded(around: center) }
    }

    func toggleVoiceSearch() async {
        if speechService.isRecording {
            speechService.stop()
        } else {
            queryText = ""
            await speechService.start()
        }
    }

    func select(_ completion: MKLocalSearchCompletion) async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            if let item = response.mapItems.first {
                selectResult(SearchResult(mapItem: item))
            } else {
                errorMessage = "No results found."
            }
        } catch {
            errorMessage = "Couldn't find that place. Try again."
        }
    }

    func selectResult(_ result: SearchResult) {
        selectedResult = result
        recentsStore.add(result)
        queryText = result.title
    }

    func selectRecent(_ recent: RecentSearch) {
        selectedResult = syntheticResult(title: recent.title, coordinate: recent.coordinate)
        queryText = recent.title
    }

    func selectFavorite(_ favorite: FavoritePlace) {
        // Deliberately searches by `favorite.title` (the real place name), not `displayTitle` —
        // a custom nickname like "Mom's House" would go straight into Google's text search and
        // fail to resolve. The nickname is a label for browsing the Favorites list, not a query.
        selectedResult = syntheticResult(title: favorite.title, coordinate: favorite.coordinate)
        queryText = favorite.title
    }

    func selectDiscover(_ place: GooglePlace) {
        guard let coordinate = place.coordinate, let name = place.displayName?.text else { return }
        let result = syntheticResult(title: name, coordinate: coordinate)
        selectedResult = result
        recentsStore.add(result)
        queryText = name
    }

    /// Opens the place card for a POI the user tapped directly on the map, exactly as if they
    /// had searched for it — Google details are then loaded from the name + coordinate.
    func selectMapFeature(_ feature: MapFeature) {
        let title = feature.title ?? "Dropped Pin"
        let result = syntheticResult(title: title, coordinate: feature.coordinate)
        selectedResult = result
        recentsStore.add(result)
        queryText = title
    }

    func clearSelection() {
        selectedResult = nil
    }

    private func syntheticResult(title: String, coordinate: CLLocationCoordinate2D) -> SearchResult {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = title
        return SearchResult(mapItem: mapItem)
    }
}
