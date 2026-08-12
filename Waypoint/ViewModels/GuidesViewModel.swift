import CoreLocation
import Foundation
import Observation

/// The "Guides" shelf on the search page.
///
/// Apple's guides are licensed editorial — Time Out, The Infatuation, Lonely Planet — and none of
/// that is available through any public API. So these are not pretending to be editorial: each
/// guide is a themed collection assembled from the highest-rated nearby places of a given type,
/// and the UI says so. The cover photo, the count and every place inside are real.
@Observable
@MainActor
final class GuidesViewModel {
    struct Guide: Identifiable {
        let id: String
        let title: String
        /// What the guide is actually built from, shown on the card so it never reads as a
        /// hand-written editorial blurb.
        let subtitle: String
        let symbol: String
        let places: [DetailedPlace]

        var coverPlace: DetailedPlace? { places.first }
    }

    private(set) var guides: [Guide] = []
    private(set) var isLoading = false

    private let service = GooglePlacesService()
    private var lastLoadedCenter: CLLocationCoordinate2D?

    /// Themes chosen to match the kinds of collection Apple surfaces, but each one maps to a
    /// concrete set of Google place types so nothing here is editorial judgement.
    private static let themes: [(id: String, title: String, symbol: String, types: [String])] = [
        (id: "coffee", title: "Great Coffee", symbol: "cup.and.saucer.fill",
         types: ["cafe", "coffee_shop"]),
        (id: "dinner", title: "Dinner Tonight", symbol: "fork.knife",
         types: ["restaurant", "fine_dining_restaurant"]),
        (id: "outdoors", title: "Parks & Outdoors", symbol: "leaf.fill",
         types: ["park", "hiking_area", "garden"]),
        (id: "nightlife", title: "Nightlife", symbol: "moon.stars.fill",
         types: ["bar", "night_club"]),
        (id: "culture", title: "Arts & Culture", symbol: "building.columns.fill",
         types: ["museum", "art_gallery", "performing_arts_theater"])
    ]

    func loadIfNeeded(around coordinate: CLLocationCoordinate2D) async {
        if let last = lastLoadedCenter, last.distance(to: coordinate) < 1000, !guides.isEmpty {
            return
        }
        lastLoadedCenter = coordinate
        isLoading = true
        defer { isLoading = false }

        // Each theme is one billed nearby search, so they run concurrently and lean on the
        // service's existing 10-minute cache rather than refetching per scroll.
        let loaded = await withTaskGroup(of: (Int, [DetailedPlace]).self) { group in
            for (index, theme) in Self.themes.enumerated() {
                group.addTask { [service] in
                    let places = (try? await service.searchNearby(
                        includedTypes: theme.types,
                        coordinate: coordinate,
                        radius: 4000,
                        maxResults: 12,
                        primaryTypesOnly: true
                    )) ?? []
                    return (index, places)
                }
            }
            var results: [Int: [DetailedPlace]] = [:]
            for await (index, places) in group { results[index] = places }
            return results
        }

        guides = Self.themes.enumerated().compactMap { index, theme in
            // Rated places only — a guide of "top rated" places can't include unrated ones, and
            // a cover card with no photo looks broken.
            let ranked = (loaded[index] ?? [])
                .filter { ($0.rating ?? 0) > 0 && $0.photos?.isEmpty == false }
                .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }

            // Below three places it isn't a collection, it's a search result.
            guard ranked.count >= 3 else { return nil }

            return Guide(
                id: theme.id,
                title: theme.title,
                subtitle: "\(ranked.count) top-rated nearby",
                symbol: theme.symbol,
                places: ranked
            )
        }
    }

    func photoURL(for place: DetailedPlace, maxWidthPx: Int = 600) -> URL? {
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
