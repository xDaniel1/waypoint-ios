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
    /// Used only when Google is unavailable — see `loadIfNeeded`.
    private let fallbackService = ApplePlacesService()
    private var lastLoadedCenter: CLLocationCoordinate2D?
    /// True when the shelves below are MapKit-sourced, so the UI can explain the thinner cards
    /// instead of silently looking broken.
    private(set) var isUsingFallbackData = false

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

        var (t, s) = await (trending, suggested)

        // Google can be unavailable for reasons that have nothing to do with this code — an
        // expired key, billing lapsing, or the Places API being switched off in Cloud Console
        // all return 403. Previously that emptied both shelves, so the whole search page looked
        // broken. Fall back to MapKit so the shelves still populate; they lose photos, ratings
        // and hours (MapKit exposes none of those), which `isUsingFallbackData` lets the UI say
        // out loud rather than leaving the user guessing.
        if t.isEmpty && s.isEmpty {
            async let fallbackTrending = (try? fallbackService.searchNearby(
                includedTypes: ["restaurant"], coordinate: coordinate, radius: 2500, maxResults: 8
            )) ?? []
            async let fallbackSuggested = (try? fallbackService.searchNearby(
                includedTypes: ["cafe"], coordinate: coordinate, radius: 2000, maxResults: 8
            )) ?? []
            (t, s) = await (fallbackTrending, fallbackSuggested)
            isUsingFallbackData = !(t.isEmpty && s.isEmpty)
        } else {
            isUsingFallbackData = false
        }

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
