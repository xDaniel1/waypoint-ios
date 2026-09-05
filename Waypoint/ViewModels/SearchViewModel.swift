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
    
    /// Tracks where the search was initiated so we can show "Search Here" when user pans away.
    var lastSearchCenter: CLLocationCoordinate2D?
    var showSearchHereButton = false

    var suggestions: [MKLocalSearchCompletion] {
        completerService.suggestions
    }

    let recentsStore = RecentSearchesStore()
    let favoritesStore = FavoritesStore()
    let speechService = SpeechRecognitionService()
    let nearbyService = NearbyPlacesService()
    let discover = DiscoverViewModel()
    let guides = GuidesViewModel()
    let cityGuides = CityGuidesViewModel()
    let nearbyDepartures = NearbyDeparturesService()
    /// Set by `MapScreen`. Departures are only fetched, and only shown, in Transit.
    var isTransitMode = false {
        didSet {
            guard isTransitMode, isTransitMode != oldValue else { return }
            loadNearbyDepartures()
        }
    }
    let syncCoordinator: SyncCoordinator

    private let completerService = SearchCompleterService()
    private var lastRegionCenter: CLLocationCoordinate2D?
    private var regionUpdateTask: Task<Void, Never>?

    // MARK: Category browse

    /// Which category pill is showing results, if any. Tapping "Restaurants" in Apple Maps
    /// *browses* a category — it runs a real nearby search and lists what's around you. Ours
    /// used to just type the word into the search field, which handed it to the autocomplete
    /// completer instead, so you got literal name matches ("Restaurant Depot", a "Restaurants
    /// Zone" in Israel) with the keyboard still up rather than the restaurants near you.
    private(set) var activeCategory: String?
    /// SF Symbol for the map pins of the active category — a fork on a gas station would be
    /// worse than no icon.
    private(set) var categorySymbol = "mappin"
    private(set) var categoryResults: [DetailedPlace] = []
    private(set) var isLoadingCategory = false
    private(set) var categoryErrorMessage: String?

    private let placesService = GooglePlacesService()
    private var categoryTask: Task<Void, Never>?

    func photoURL(forCategoryResult place: DetailedPlace, maxWidthPx: Int = 200) -> URL? {
        guard let photo = place.photos?.first else { return nil }
        return placesService.photoURL(photoName: photo.name, maxWidthPx: maxWidthPx)
    }

    /// Tapping the open category again closes it, matching how the rest of the card's toggles
    /// behave rather than stacking state.
    func browseCategory(
        title: String,
        symbol: String,
        includedTypes: [String],
        near coordinate: CLLocationCoordinate2D?
    ) {
        categoryTask?.cancel()
        guard activeCategory != title else {
            clearCategory()
            return
        }
        guard let coordinate = coordinate ?? lastRegionCenter else {
            categoryErrorMessage = "Waiting for your location."
            return
        }
        activeCategory = title
        categorySymbol = symbol
        categoryResults = []
        categoryErrorMessage = nil
        lastSearchCenter = coordinate
        showSearchHereButton = false
        // Apple puts the category name in the field while browsing. Setting it here also feeds
        // the completer, but the category results take precedence over suggestions in the list,
        // and typing anything else drops the category (see SearchSheet's queryText onChange).
        queryText = title
        categoryTask = Task {
            isLoadingCategory = true
            defer { isLoadingCategory = false }
            do {
                let places = try await placesService.searchNearby(
                    includedTypes: includedTypes, coordinate: coordinate, radius: 5000, maxResults: 20
                )
                if Task.isCancelled { return }
                categoryResults = places
                if places.isEmpty {
                    categoryErrorMessage = "No \(title.lowercased()) found nearby."
                }
            } catch {
                if Task.isCancelled { return }
                categoryErrorMessage = "Couldn't load nearby \(title.lowercased())."
            }
        }
    }

    func clearCategory(clearingQuery: Bool = false) {
        categoryTask?.cancel()
        if clearingQuery, queryText == activeCategory {
            queryText = ""
        }
        activeCategory = nil
        categoryResults = []
        categoryErrorMessage = nil
        isLoadingCategory = false
    }

    // Explicit so `syncCoordinator` can wire itself into `favoritesStore`/`recentsStore` after
    // their own (default-valued) initializers have already run.
    init() {
        syncCoordinator = SyncCoordinator(favoritesStore: favoritesStore, recentsStore: recentsStore)
    }

    func updateSearchRegion(_ region: MKCoordinateRegion) {
        completerService.updateRegion(region)
        let newCenter = region.center
        if let last = lastSearchCenter {
            let distance = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: newCenter.latitude, longitude: newCenter.longitude))
            if distance > 400 && (isSearching || selectedResult != nil || queryText.isEmpty == false) {
                showSearchHereButton = true
            }
        }
        lastRegionCenter = newCenter

        // Settle for a beat before asking for nearby points of interest. A pan fires this
        // continuously, and every intermediate region was starting its own `MKLocalSearch` only to
        // be thrown away by the next one. Nothing billed is saved here — that lookup is Apple's,
        // not Google's — but it stops a drag across the city from queueing dozens of searches.
        regionUpdateTask?.cancel()
        regionUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await nearbyService.refresh(around: region)
        }
    }
    
    func searchInCurrentRegion(center: CLLocationCoordinate2D) {
        lastSearchCenter = center
        showSearchHereButton = false
        if let region = lastRegionCenter {
            let mkRegion = MKCoordinateRegion(center: region, latitudinalMeters: 5000, longitudinalMeters: 5000)
            updateSearchRegion(mkRegion)
        }
    }

    func loadDiscover() {
        guard let center = lastRegionCenter else { return }
        Task { await discover.loadIfNeeded(around: center) }
        Task { await guides.loadIfNeeded(around: center) }
        Task { await cityGuides.loadIfNeeded(around: center) }
        // Covers switching to Transit before the map has ever settled — `loadNearbyDepartures`
        // needs a region and there wasn't one yet, so that call did nothing and never retried.
        if isTransitMode { loadNearbyDepartures() }
    }

    /// Not folded into `loadDiscover` unconditionally: the GTFS-RT feeds are 20KB–1MB each and
    /// only one mode ever displays them, so they're pulled when Transit is on screen rather than
    /// on every launch for everyone.
    func loadNearbyDepartures() {
        guard let center = lastRegionCenter else { return }
        Task { await nearbyDepartures.refreshIfNeeded(near: center) }
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
        lastSearchCenter = result.coordinate
        showSearchHereButton = false
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

    func selectDiscover(_ place: DetailedPlace) {
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
        // Panning away sets this; without clearing it here the pill stayed on screen forever
        // once you dismissed the search that raised it.
        showSearchHereButton = false
        selectedResult = nil
        clearCategory()
    }

    private func syntheticResult(title: String, coordinate: CLLocationCoordinate2D) -> SearchResult {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = title
        return SearchResult(mapItem: mapItem)
    }
}
