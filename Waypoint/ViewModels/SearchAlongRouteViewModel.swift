import CoreLocation
import Observation

/// Browses Google Places near the road ahead during active navigation — Apple Maps' "search
/// along route" for gas, food, coffee, EV charging, and parking.
///
/// Honest simplification: this searches around a single point roughly a third of the way along
/// the remaining route, not a true corridor along the whole remaining polyline. Building an
/// actual corridor search (bucketing results by how close they sit to the route line, not just
/// to one point on it) is real additional work; this gets "things generally ahead of you"
/// without overclaiming precision it doesn't have.
@Observable
@MainActor
final class SearchAlongRouteViewModel {
    enum Category: String, CaseIterable, Identifiable {
        case gas, food, coffee, evCharging, parking

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gas: "Gas"
            case .food: "Food"
            case .coffee: "Coffee"
            case .evCharging: "EV Charging"
            case .parking: "Parking"
            }
        }

        var symbol: String {
            switch self {
            case .gas: "fuelpump.fill"
            case .food: "fork.knife"
            case .coffee: "cup.and.saucer.fill"
            case .evCharging: "bolt.car.fill"
            case .parking: "parkingsign"
            }
        }

        var placeTypes: [String] {
            switch self {
            case .gas: ["gas_station"]
            case .food: ["restaurant"]
            case .coffee: ["cafe"]
            case .evCharging: ["electric_vehicle_charging_station"]
            case .parking: ["parking"]
            }
        }
    }

    private(set) var selectedCategory: Category?
    private(set) var results: [DetailedPlace] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let service = GooglePlacesService()
    private var searchTask: Task<Void, Never>?

    func select(_ category: Category, along remainingCoordinates: [CLLocationCoordinate2D]) {
        selectedCategory = category
        searchTask?.cancel()
        searchTask = Task {
            isLoading = true
            errorMessage = nil
            results = []
            defer { isLoading = false }

            guard let aheadPoint = Self.pointAhead(in: remainingCoordinates) else {
                errorMessage = "Not enough of the route left to search ahead."
                return
            }
            do {
                let places = try await service.searchNearby(
                    includedTypes: category.placeTypes,
                    coordinate: aheadPoint,
                    radius: 4000,
                    maxResults: 8
                )
                guard !Task.isCancelled else { return }
                results = places
                if places.isEmpty { errorMessage = "No \(category.label.lowercased()) found ahead." }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Couldn't search along the route."
            }
        }
    }

    func photoURL(for place: DetailedPlace, maxWidthPx: Int = 400) -> URL? {
        guard let photo = place.photos?.first else { return nil }
        return service.photoURL(photoName: photo.name, maxWidthPx: maxWidthPx)
    }

    /// A point about a third of the way along what's left of the route — "ahead" without being
    /// so far out that it's past where the driver will actually be by the time they get there.
    private static func pointAhead(in coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        let index = min(coordinates.count - 1, coordinates.count / 3)
        return coordinates[index]
    }
}
