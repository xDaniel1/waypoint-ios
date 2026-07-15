import Foundation
import Observation

@Observable
@MainActor
final class PlaceDetailViewModel {
    private(set) var place: GooglePlace?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let service = GooglePlacesService()

    func load(for result: SearchResult) async {
        isLoading = true
        errorMessage = nil
        place = nil
        do {
            place = try await service.findPlace(name: result.title, coordinate: result.coordinate)
        } catch GooglePlacesError.missingAPIKey {
            errorMessage = "Add a Google Places API key to Secrets.xcconfig to see photos, ratings, and reviews."
        } catch GooglePlacesError.noMatch {
            errorMessage = "No extended details found for this place."
        } catch {
            errorMessage = "Couldn't load details for this place."
        }
        isLoading = false
    }

    func photoURL(for photo: GooglePlace.Photo, maxWidthPx: Int = 800) -> URL? {
        service.photoURL(photoName: photo.name, maxWidthPx: maxWidthPx)
    }
}
