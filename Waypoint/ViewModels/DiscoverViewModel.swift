import CoreLocation
import Foundation
import Observation

/// Loads Google-powered discovery content (trending restaurants + suggested nearby places)
/// for the browse state of the search sheet — our take on Apple Maps' Suggested/Trending sections.
@Observable
@MainActor
final class DiscoverViewModel {
    private(set) var trendingRestaurants: [GooglePlace] = []
    private(set) var suggestedPlaces: [GooglePlace] = []
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

    func photoURL(for place: GooglePlace, maxWidthPx: Int = 400) -> URL? {
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
