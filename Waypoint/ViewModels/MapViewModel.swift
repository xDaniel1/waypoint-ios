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

    /// Radius the current fix is confident to, in metres; drives the accuracy halo under the
    /// blue dot. Negative when there's no valid fix yet.
    var horizontalAccuracy: CLLocationAccuracy {
        locationManager.horizontalAccuracy
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

    /// Called when turn-by-turn navigation starts — the contextually-right moment to ask for
    /// Always authorization (Apple rejects apps that ask upfront) and to let updates keep
    /// flowing if the driver backgrounds the app mid-trip.
    func beginBackgroundTracking(driving: Bool) {
        locationManager.requestAlwaysPermission()
        locationManager.setBackgroundUpdatesEnabled(true)
        // Road snapping is a help in a car and a liability on a train — it drags the fix onto
        // the nearest street, which for an above-ground subway is the avenue beside the tracks.
        locationManager.setProfile(driving ? .driving : .navigating)
    }

    /// Called when navigation ends, so the app isn't tracking location in the background once
    /// there's no active trip to track.
    func endBackgroundTracking() {
        locationManager.setBackgroundUpdatesEnabled(false)
        locationManager.setProfile(.navigating)
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

    /// Resets pitch to flat 2D when exiting directions or navigation.
    func resetTo2D(from camera: MapCamera?) {
        guard let camera, camera.pitch > 1 else { return }
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: camera.centerCoordinate,
                distance: camera.distance,
                heading: camera.heading,
                pitch: 0
            )
        )
    }

    /// The location button's first tap: put me back on screen.
    ///
    /// Apple recenters at the zoom you were already at — coming back to yourself after panning
    /// two blocks away shouldn't rescale the street you were reading. It only picks a zoom for
    /// you when the current one is no use for "where am I": staring at the whole state, or
    /// pushed in so far there's no context left. This used to slam every tap to a fixed 0.01°
    /// span regardless.
    func recenterOnUser(camera: MapCamera? = nil) {
        guard let location = currentLocation else { return }
        guard let distance = camera?.distance else {
            centerCamera(on: location.coordinate)
            return
        }
        let usefulRange: ClosedRange<Double> = 150...6_000
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: location.coordinate,
                distance: usefulRange.contains(distance) ? distance : 1_200,
                heading: 0,
                pitch: camera?.pitch ?? 0
            )
        )
    }

    /// Apple Maps' compass mode: the second tap of the location button. It spins the map so the
    /// direction you're facing points up — and that is *all* it does. The zoom you picked and
    /// whether you were tilted both survive.
    ///
    /// This used to route through `followUser`, which hard-codes a 400m tilted navigation
    /// camera, so asking for "point the map where I'm facing" while browsing slammed you into
    /// a 3D street-level view you never asked for.
    func orientToHeading(at location: CLLocation, heading: CLLocationDirection, camera: MapCamera?) {
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: location.coordinate,
                distance: camera?.distance ?? 1000,
                heading: heading >= 0 ? heading : 0,
                pitch: camera?.pitch ?? 0
            )
        )
    }

    /// Leaving compass mode: swing back to north-up over the user without throwing away their
    /// zoom, which `recenterOnUser`'s fixed 0.01° span was doing.
    func straightenToNorth(at location: CLLocation, camera: MapCamera?) {
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: location.coordinate,
                distance: camera?.distance ?? 1000,
                heading: 0,
                pitch: camera?.pitch ?? 0
            )
        )
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
