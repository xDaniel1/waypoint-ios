import MapKit
import Observation

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
    let speechService = SpeechRecognitionService()
    let nearbyService = NearbyPlacesService()

    private let completerService = SearchCompleterService()

    func updateSearchRegion(_ region: MKCoordinateRegion) {
        completerService.updateRegion(region)
        Task { await nearbyService.refresh(around: region) }
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
        let placemark = MKPlacemark(coordinate: recent.coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = recent.title
        selectedResult = SearchResult(mapItem: mapItem)
        queryText = recent.title
    }

    func clearSelection() {
        selectedResult = nil
    }
}
