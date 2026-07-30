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

    var currentLocation: CLLocation? {
        locationManager.currentLocation
    }

    /// Magnetometer+gyro-fused device heading; used to rotate the nav camera live as the
    /// phone turns, since GPS course alone doesn't update while stationary or moving slowly.
    var currentHeading: CLLocationDirection? {
        locationManager.currentHeading
    }

    var currentHeadingAccuracy: CLLocationDirection? {
        locationManager.currentHeadingAccuracy
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

    func fitCamera(toRoute mapRect: MKMapRect) {
        cameraPosition = .rect(mapRect)
    }

    /// Toggles between flat (2D) and tilted (3D) using the live camera so zoom/center are preserved.
    func toggle3D(from camera: MapCamera?) {
        guard let camera else { return }
        let newPitch: CGFloat = camera.pitch > 1 ? 0 : 55
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: camera.centerCoordinate,
                distance: camera.distance,
                heading: camera.heading,
                pitch: newPitch
            )
        )
    }

    func recenterOnUser() {
        guard let location = currentLocation else { return }
        centerCamera(on: location.coordinate)
    }

    /// Keeps the map centered on a moving user without rotating it or resetting the zoom
    /// the person already chose — used for plain "follow" tracking outside of navigation.
    func recenterKeepingZoom(on location: CLLocation, camera: MapCamera?) {
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: location.coordinate,
                distance: camera?.distance ?? 1000,
                heading: 0,
                pitch: 0
            )
        )
    }

    /// Follow-camera used during navigation: tilted 3D, oriented toward the user's heading.
    func followUser(at location: CLLocation, heading: CLLocationDirection) {
        let heading = heading >= 0 ? heading : 0
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: location.coordinate,
                distance: 400,
                heading: heading,
                pitch: 55
            )
        )
    }

    func resetHeading(from camera: MapCamera?) {
        guard let camera else { return }
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: camera.centerCoordinate,
                distance: camera.distance,
                heading: 0,
                pitch: camera.pitch
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
