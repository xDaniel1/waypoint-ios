import CoreLocation
import Foundation
import SwiftUI
import MapKit

enum ApplePlacesError: Error {
    case noMatch
    case requestFailed
}

struct ApplePlacesService {
    
    init() {}

    func findPlace(name: String, coordinate: CLLocationCoordinate2D) async throws -> DetailedPlace {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 200, longitudinalMeters: 200)
        let search = MKLocalSearch(request: request)
        
        let response = try await search.start()
        guard let mapItem = response.mapItems.first else {
            throw ApplePlacesError.noMatch
        }
        
        return DetailedPlace(mapItem: mapItem)
    }

    func searchNearby(
        includedTypes: [String],
        coordinate: CLLocationCoordinate2D,
        radius: Double = 2000,
        maxResults: Int = 8
    ) async throws -> [DetailedPlace] {
        // MapKit doesn't easily filter by array of types in the same way, we just do a generic search
        // or search by category. We'll do a generic nearby search for the first included type, or "places".
        let query = includedTypes.first?.replacingOccurrences(of: "_", with: " ") ?? "places"
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: radius, longitudinalMeters: radius)
        let search = MKLocalSearch(request: request)
        
        do {
            let response = try await search.start()
            return response.mapItems.prefix(maxResults).map { DetailedPlace(mapItem: $0) }
        } catch {
            return []
        }
    }

    func placeDetails(placeId: String) async throws -> DetailedPlace {
        // MKLocalSearch doesn't have a lookup by placeId directly via public API.
        // For our cache/id purposes, since we only call placeDetails if we already searched,
        // we can just throw if we hit this, or we can just fall back to a text search for the ID assuming it's the title.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = placeId
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else { throw ApplePlacesError.noMatch }
        return DetailedPlace(mapItem: item)
    }

    func photoURL(photoName: String, maxWidthPx: Int = 800) -> URL? {
        return nil
    }

    func fetchPhotoURL(photoName: String, maxWidthPx: Int = 800) async -> URL? {
        return nil
    }
}

/// A stub view since we aren't using Google's direct photo URLs anymore
struct DetailedPlacePhotoView: View {
    let photoName: String?
    var maxWidthPx: Int = 800
    var contentMode: ContentMode = .fill

    var body: some View {
        Rectangle().fill(.quaternary).clipped()
    }
}
