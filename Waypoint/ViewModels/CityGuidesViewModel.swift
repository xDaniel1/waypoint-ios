import CoreLocation
import Foundation
import OSLog
import Observation

/// The "City Guides" shelf: nearby major cities, each opening to that city's top-rated
/// attractions.
///
/// Apple's city guides are editorial. There's no public API for "which cities does Apple think
/// are worth a guide" or "what's the best of Philadelphia" — so this picks from a fixed list of
/// well-known cities (real names and coordinates, the same kind of static reference table as the
/// category pills or the OSM road-classification ranks elsewhere in this codebase) and ranks the
/// nearest ones. Every place inside a city guide is a live, top-rated nearby-search result for
/// that city's own coordinate — nothing about a specific place is invented.
@Observable
@MainActor
final class CityGuidesViewModel {
    struct CityGuide: Identifiable {
        let id: String
        let name: String
        let region: String
        let places: [DetailedPlace]

        var coverPlace: DetailedPlace? { places.first }
    }

    private(set) var cityGuides: [CityGuide] = []
    private(set) var isLoading = false

    private let service = GooglePlacesService()
    private var lastLoadedCenter: CLLocationCoordinate2D?

    private struct City {
        let name: String
        let region: String
        let coordinate: CLLocationCoordinate2D
    }

    /// Major U.S. metros. Real names and real coordinates — the only thing "curated" here is
    /// which cities are worth listing at all, same as Apple's own City Guides picks a fixed set.
    private static let cities: [City] = [
        City(name: "New York", region: "United States", coordinate: .init(latitude: 40.7128, longitude: -74.0060)),
        City(name: "Philadelphia", region: "United States", coordinate: .init(latitude: 39.9526, longitude: -75.1652)),
        City(name: "Boston", region: "United States", coordinate: .init(latitude: 42.3601, longitude: -71.0589)),
        City(name: "Washington", region: "United States", coordinate: .init(latitude: 38.9072, longitude: -77.0369)),
        City(name: "Baltimore", region: "United States", coordinate: .init(latitude: 39.2904, longitude: -76.6122)),
        City(name: "Chicago", region: "United States", coordinate: .init(latitude: 41.8781, longitude: -87.6298)),
        City(name: "Pittsburgh", region: "United States", coordinate: .init(latitude: 40.4406, longitude: -79.9959)),
        City(name: "Atlanta", region: "United States", coordinate: .init(latitude: 33.7490, longitude: -84.3880)),
        City(name: "Miami", region: "United States", coordinate: .init(latitude: 25.7617, longitude: -80.1918)),
        City(name: "New Orleans", region: "United States", coordinate: .init(latitude: 29.9511, longitude: -90.0715)),
        City(name: "Nashville", region: "United States", coordinate: .init(latitude: 36.1627, longitude: -86.7816)),
        City(name: "Detroit", region: "United States", coordinate: .init(latitude: 42.3314, longitude: -83.0458)),
        City(name: "Minneapolis", region: "United States", coordinate: .init(latitude: 44.9778, longitude: -93.2650)),
        City(name: "Dallas", region: "United States", coordinate: .init(latitude: 32.7767, longitude: -96.7970)),
        City(name: "Houston", region: "United States", coordinate: .init(latitude: 29.7604, longitude: -95.3698)),
        City(name: "Austin", region: "United States", coordinate: .init(latitude: 30.2672, longitude: -97.7431)),
        City(name: "Denver", region: "United States", coordinate: .init(latitude: 39.7392, longitude: -104.9903)),
        City(name: "Phoenix", region: "United States", coordinate: .init(latitude: 33.4484, longitude: -112.0740)),
        City(name: "Las Vegas", region: "United States", coordinate: .init(latitude: 36.1699, longitude: -115.1398)),
        City(name: "San Francisco", region: "United States", coordinate: .init(latitude: 37.7749, longitude: -122.4194)),
        City(name: "Los Angeles", region: "United States", coordinate: .init(latitude: 34.0522, longitude: -118.2437)),
        City(name: "San Diego", region: "United States", coordinate: .init(latitude: 32.7157, longitude: -117.1611)),
        City(name: "Seattle", region: "United States", coordinate: .init(latitude: 47.6062, longitude: -122.3321)),
        City(name: "Portland", region: "United States", coordinate: .init(latitude: 45.5152, longitude: -122.6784)),
    ]

    func loadIfNeeded(around coordinate: CLLocationCoordinate2D) async {
        if let last = lastLoadedCenter, last.distance(to: coordinate) < 5000, !cityGuides.isEmpty {
            return
        }
        lastLoadedCenter = coordinate

        // Nearest 6, but skip the one the user is already standing in — a "New York City guide"
        // card while you're in New York is the one Apple never shows either.
        let nearby = Self.cities
            .map { ($0, $0.coordinate.distance(to: coordinate)) }
            .filter { $0.1 > 15_000 }
            .sorted { $0.1 < $1.1 }
            .prefix(6)
            .map(\.0)

        guard !nearby.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let loaded = await withTaskGroup(of: (Int, [DetailedPlace]).self) { group in
            for (index, city) in nearby.enumerated() {
                group.addTask { [service, name = city.name] in
                    do {
                        let places = try await service.searchNearby(
                            includedTypes: ["tourist_attraction", "museum", "park", "historical_landmark"],
                            coordinate: city.coordinate,
                            radius: 12000,
                            maxResults: 12,
                            primaryTypesOnly: true
                        )
                        return (index, places)
                    } catch {
                        // A swallowed `try?` here once hid an invalid place-type value for 70+
                        // seconds of test failures before the real 400 turned up in a raw curl.
                        Logger.places.error("City guide fetch failed for \(name): \(error.localizedDescription)")
                        return (index, [])
                    }
                }
            }
            var results: [Int: [DetailedPlace]] = [:]
            for await (index, places) in group { results[index] = places }
            return results
        }

        cityGuides = nearby.enumerated().compactMap { index, city in
            let ranked = (loaded[index] ?? [])
                .filter { ($0.rating ?? 0) > 0 && $0.photos?.isEmpty == false }
                .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
            guard ranked.count >= 3 else { return nil }
            return CityGuide(id: city.name, name: city.name, region: city.region, places: ranked)
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
