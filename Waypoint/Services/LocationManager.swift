import CoreLocation
import Observation

@Observable
@MainActor
final class LocationManager {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentLocation: CLLocation?

    private let manager = CLLocationManager()

    init() {
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Streams location updates until permission is revoked or the task is cancelled.
    func startUpdating(onLocation: @escaping (CLLocation) -> Void) async {
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
