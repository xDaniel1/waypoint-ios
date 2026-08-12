import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class PlaceDetailViewModel {
    private(set) var place: DetailedPlace?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let googleService = GooglePlacesService()
    private let appleService = ApplePlacesService()

    /// Google is the only source that returns photos, ratings, reviews and hours, so the card
    /// asks it first. Apple is the fallback when there's no API key configured or the lookup
    /// fails — the card then renders name/category/address/phone only, which is genuinely all
    /// MapKit exposes, rather than showing an error over an otherwise usable place.
    func load(for result: SearchResult) async {
        isLoading = true
        errorMessage = nil
        place = nil
        defer { isLoading = false }

        if googleService.isConfigured {
            do {
                place = try await googleService.details(name: result.title, coordinate: result.coordinate)
                return
            } catch {
                Logger.places.error("Google Places details failed, falling back to MapKit: \(error.localizedDescription)")
                // Fall through to MapKit rather than leaving the card empty.
            }
        }

        do {
            place = try await appleService.findPlace(name: result.title, coordinate: result.coordinate)
        } catch {
            errorMessage = "Couldn't load place details."
        }
    }

    /// Only Google-sourced places carry photos; an Apple-sourced fallback has none, and this
    /// correctly returns nil for them rather than producing a dead URL.
    func photoURL(for photo: DetailedPlace.Photo, maxWidthPx: Int = 800) -> URL? {
        googleService.photoURL(photoName: photo.name, maxWidthPx: maxWidthPx)
    }
}
