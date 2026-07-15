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

    private let locationManager: LocationManager
    private var hasCenteredOnUser = false

    init(locationManager: LocationManager = LocationManager()) {
        self.locationManager = locationManager
    }

    func start() async {
        locationManager.requestPermission()
        await locationManager.startUpdating { [weak self] location in
            self?.centerOnUserLocation(location)
        }
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
