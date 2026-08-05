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

    /// Reported heading uncertainty in degrees; drives how wide the nav puck's cone renders.
    private(set) var currentHeadingAccuracy: CLLocationDirection?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Apple rejects apps that ask for Always upfront, so this is only called once the driver
    /// actually starts turn-by-turn navigation — the moment background tracking becomes
    /// something they'd plausibly want, not on first launch. If they'd already said no to
    /// When In Use, iOS just re-shows the same When-In-Use-only state; it can't be upgraded
    /// silently.
    func requestAlwaysPermission() {
        manager.requestAlwaysAuthorization()
    }

    /// Lets location updates continue once the app is backgrounded — only meaningful with
    /// "Always" authorization; with just "When In Use", iOS pauses updates in the background
    /// regardless of this flag. Only turned on while a trip is actually active, and turned back
    /// off when it ends, so the app isn't tracking location in the background for no reason.
    func setBackgroundUpdatesEnabled(_ enabled: Bool) {
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = !enabled
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
        let accuracy = newHeading.headingAccuracy
        Task { @MainActor in
            self.currentHeading = heading
            self.currentHeadingAccuracy = accuracy
        }
    }
}
