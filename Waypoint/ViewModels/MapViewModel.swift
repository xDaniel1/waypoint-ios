import CoreLocation
import MapKit
import Observation
import SwiftUI

@Observable
@MainActor
final class MapViewModel {
    var cameraPosition: MapCameraPosition = .automatic

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    /// Called on every location update; consumers should debounce/guard for one-shot work like a weather fetch.
    var onLocationUpdate: ((CLLocation) -> Void)?

    private let locationManager: LocationManager
    private var hasCenteredOnUser = false

    init(locationManager: LocationManager = LocationManager()) {
        self.locationManager = locationManager
    }

    func start() async {
        locationManager.requestPermission()
        await locationManager.startUpdating { [weak self] location in
            self?.centerOnUserLocation(location)
            self?.onLocationUpdate?(location)
        }
    }

    func centerCamera(on coordinate: CLLocationCoordinate2D) {
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
    }

    private func centerOnUserLocation(_ location: CLLocation) {
        guard !hasCenteredOnUser else { return }
        hasCenteredOnUser = true
        cameraPosition = .region(
            MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        )
    }
}
