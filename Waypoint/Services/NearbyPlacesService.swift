import MapKit
import Observation

@Observable
@MainActor
final class NearbyPlacesService {
    private(set) var nearbyResults: [SearchResult] = []

    func refresh(around region: MKCoordinateRegion) async {
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            nearbyResults = response.mapItems.prefix(5).map { SearchResult(mapItem: $0) }
        } catch {
            nearbyResults = []
        }
    }
}
