import CoreLocation
import Foundation
import Observation

/// Drives the home card's "Around Me" quick-category grid: tapping Gas/Food/EV Charging runs a
/// real Google Places Nearby Search around the user's current location, not a canned list.
@Observable
@MainActor
final class AroundMeViewModel {
    enum Category: String, CaseIterable, Identifiable {
        case gas, food, evCharging

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gas: "Gas"
            case .food: "Food"
            case .evCharging: "EV Charging"
            }
        }

        var symbol: String {
            switch self {
            case .gas: "fuelpump.fill"
            case .food: "fork.knife"
            case .evCharging: "bolt.car.fill"
            }
        }

        var includedTypes: [String] {
            switch self {
            case .gas: ["gas_station"]
            case .food: ["restaurant"]
            case .evCharging: ["electric_vehicle_charging_station"]
            }
        }
    }

    private(set) var selectedCategory: Category?
    private(set) var results: [GooglePlace] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let service = GooglePlacesService()
    private var searchTask: Task<Void, Never>?

    /// Tapping the already-open category collapses the grid back down, matching how the rest
    /// of the home card's "see all" chevrons toggle rather than stacking new state.
    func select(_ category: Category, near coordinate: CLLocationCoordinate2D) {
        searchTask?.cancel()
        guard selectedCategory != category else {
            selectedCategory = nil
            results = []
            errorMessage = nil
            return
        }
        selectedCategory = category
        results = []
        errorMessage = nil
        searchTask = Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let places = try await service.searchNearby(
                    includedTypes: category.includedTypes, coordinate: coordinate, radius: 8000, maxResults: 10
                )
                if Task.isCancelled { return }
                results = places
            } catch {
                if Task.isCancelled { return }
                errorMessage = "Couldn't load nearby \(category.title.lowercased())."
            }
        }
    }

    func photoURL(for place: GooglePlace, maxWidthPx: Int = 400) -> URL? {
        guard let photo = place.photos?.first else { return nil }
        return service.photoURL(photoName: photo.name, maxWidthPx: maxWidthPx)
    }
}
