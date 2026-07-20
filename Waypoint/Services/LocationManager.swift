import CoreLocation
import Observation

@Observable
@MainActor
final class LocationManager: NSObject {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentLocation: CLLocation?

    /// Device heading fused from the magnetometer and gyroscope — far more responsive than
    /// GPS course, and (unlike GPS course) works while stationary or turning slowly. This is
    /// what drives the navigation camera's live rotation as the phone turns.
    private(set) var currentHeading: CLLocationDirection?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Streams location updates until permission is revoked or the task is cancelled.
    func startUpdating(onLocation: @escaping (CLLocation) -> Void) async {
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                authorizationStatus = manager.authorizationStatus
                if let location = update.location {
                    currentLocation = location
                    onLocation(location)
                }
            }
        } catch {
            authorizationStatus = manager.authorizationStatus
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.currentHeading = heading
        }
    }
}
