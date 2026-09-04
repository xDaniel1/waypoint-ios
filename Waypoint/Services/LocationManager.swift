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
    ///
    /// Low-pass filtered (see `smoothedHeading`): the raw magnetometer wobbles several degrees
    /// at rest and a lot more on a moving train, and feeding that straight to the camera made
    /// the whole map twitch.
    private(set) var currentHeading: CLLocationDirection?

    /// Reported heading uncertainty in degrees; drives how wide the nav puck's cone renders.
    private(set) var currentHeadingAccuracy: CLLocationDirection?

    /// Radius in metres that the current fix is confident to. Drawn as the halo around the blue
    /// dot, the way iOS does — the honest way to show "we're not sure exactly where you are"
    /// in a subway station or an urban canyon, instead of a crisp dot in the wrong place.
    /// Negative means the fix is invalid; we never publish those.
    private(set) var horizontalAccuracy: CLLocationAccuracy = -1

    /// How the OS should be sourcing fixes.
    ///
    /// `.otherNavigation` is the vehicular-but-not-car profile — continuous, highest-accuracy
    /// fixes, no automotive road snapping — which is the right one for a rider on a train or
    /// walking a platform. A driving trip switches to `.automotiveNavigation`, where road
    /// snapping genuinely helps.
    ///
    /// This used to be left at `liveUpdates()`'s default, a low-power profile that coalesces
    /// updates and reports at a coarser accuracy. On a moving train that's what made the dot
    /// arrive in laggy jumps.
    ///
    /// It costs more battery than the default, and that's a deliberate trade rather than an
    /// oversight: `liveUpdates` only delivers while the app is in the foreground (or during a
    /// trip, which is the case that already opts into background updates), so the extra draw
    /// only happens while someone is actually looking at the map.
    enum Profile: Equatable {
        case navigating, driving

        var liveConfiguration: CLLocationUpdate.LiveConfiguration {
            switch self {
            case .navigating: .otherNavigation
            case .driving: .automotiveNavigation
            }
        }
    }

    private(set) var profile: Profile = .navigating

    private let manager = CLLocationManager()
    /// The in-flight `liveUpdates` iteration. Cancelled and re-created when `configuration`
    /// changes, since the configuration is fixed for the lifetime of a stream.
    private var streamTask: Task<Void, Never>?
    private var isRestartingForConfiguration = false
    private var smoothedHeading: CLLocationDirection?

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

    /// Swaps the live-updates profile mid-session. The stream has to be torn down and rebuilt
    /// because `liveUpdates(_:)` bakes its configuration in at creation; `startUpdating`'s outer
    /// loop does the rebuilding so callers don't have to re-await anything.
    func setProfile(_ new: Profile) {
        guard new != profile else { return }
        profile = new
        isRestartingForConfiguration = true
        streamTask?.cancel()
    }

    /// Streams location updates until permission is revoked or the task is cancelled.
    func startUpdating(onLocation: @escaping (CLLocation) -> Void) async {
        if CLLocationManager.headingAvailable() {
            // Default is `kCLHeadingFilterNone`, i.e. every single magnetometer sample. That
            // fires tens of times a second and each one used to schedule a camera animation.
            manager.headingFilter = 2
            manager.startUpdatingHeading()
        }

        while !Task.isCancelled {
            let configuration = profile.liveConfiguration
            let task = Task { @MainActor in
                do {
                    for try await update in CLLocationUpdate.liveUpdates(configuration) {
                        authorizationStatus = manager.authorizationStatus
                        guard let location = update.location, accept(location) else { continue }
                        currentLocation = location
                        horizontalAccuracy = location.horizontalAccuracy
                        onLocation(location)
                    }
                } catch {
                    authorizationStatus = manager.authorizationStatus
                }
            }
            streamTask = task
            await task.value
            // The stream only ends on cancellation or on CoreLocation giving up. Restart it
            // only when we cancelled it ourselves to change profile — otherwise looping here
            // would spin hot against a permission denial.
            guard isRestartingForConfiguration else { break }
            isRestartingForConfiguration = false
        }
    }

    /// Screens out fixes that can't be true. CoreLocation documents a negative
    /// `horizontalAccuracy` as "this fix is invalid", and a fix that implies the phone moved
    /// faster than any ground vehicle is a GPS glitch — the kind that throws the dot a block
    /// sideways coming out of a tunnel. Everything else is published as-is; a genuinely
    /// uncertain fix is shown as an uncertain fix (a wide halo), not hidden or smoothed into
    /// a position the phone never actually reported.
    private func accept(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard let previous = currentLocation else { return true }
        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return false }
        let impliedSpeed = location.distance(from: previous) / elapsed
        return impliedSpeed < 250
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        Task { @MainActor in
            self.currentHeading = self.smooth(heading)
            self.currentHeadingAccuracy = accuracy
        }
    }

    /// Circular exponential moving average. Plain averaging breaks across the 359°/0° seam, so
    /// the step is taken on the shortest signed arc between old and new and then wrapped back
    /// into 0..<360.
    @MainActor
    private func smooth(_ heading: CLLocationDirection) -> CLLocationDirection {
        guard let previous = smoothedHeading else {
            smoothedHeading = heading
            return heading
        }
        var delta = heading - previous
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var result = previous + delta * 0.25
        if result < 0 { result += 360 }
        if result >= 360 { result -= 360 }
        smoothedHeading = result
        return result
    }
}
