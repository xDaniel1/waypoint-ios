import CoreLocation
import Foundation
import Observation

/// Discovery content for the browse state of the search sheet — the Suggested Places and
/// Trending Restaurants shelves. Google-backed rather than MapKit-backed specifically because
/// these shelves are photo-led: MapKit returns no photos, ratings, price or open/closed state,
/// which left the cards as empty grey frames.
@Observable
@MainActor
final class DiscoverViewModel {
    private(set) var trendingRestaurants: [DetailedPlace] = []
    private(set) var suggestedPlaces: [DetailedPlace] = []
    private(set) var isLoading = false

    private let service = GooglePlacesService()
    private var lastLoadedCenter: CLLocationCoordinate2D?

    func loadIfNeeded(around coordinate: CLLocationCoordinate2D) async {
        // Skip refetching if we already loaded for a nearby center (~500m).
        if let last = lastLoadedCenter, last.distance(to: coordinate) < 500,
           !trendingRestaurants.isEmpty {
            return
        }
        lastLoadedCenter = coordinate
        isLoading = true
        defer { isLoading = false }

        async let trending = (try? service.searchNearby(
            includedTypes: ["restaurant"], coordinate: coordinate, radius: 2500, maxResults: 8
        )) ?? []
        async let suggested = (try? service.searchNearby(
            includedTypes: ["cafe", "bar", "tourist_attraction", "park"],
            coordinate: coordinate, radius: 2000, maxResults: 8
        )) ?? []

        let (t, s) = await (trending, suggested)
        trendingRestaurants = t
        suggestedPlaces = s
    }

    func photoURL(for place: DetailedPlace, maxWidthPx: Int = 400) -> URL? {
        guard let photo = place.photos?.first else { return nil }
        return service.photoURL(photoName: photo.name, maxWidthPx: maxWidthPx)
    }
}

private extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
