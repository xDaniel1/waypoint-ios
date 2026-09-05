import Network
import Observation

/// Tracks whether the device currently has a usable network path.
///
/// The app leans hard on disk-cached data by design, so it stays mostly usable offline — but a
/// place search, a fresh route, or a photo that isn't cached yet will just spin silently with no
/// explanation. Surfacing connectivity lets the UI say so instead.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.danielguzman.waypoint.network-monitor")

    /// The same answer, readable from any isolation domain.
    ///
    /// `isConnected` is main-actor state because it drives the UI. The caches and services that
    /// need to know whether to fall back to stale data run off the main actor and can't await a
    /// hop just to read a flag, and they only need the last known answer rather than a
    /// guaranteed-current one — a fetch attempted a moment after the path dropped just fails and
    /// falls back anyway. Written only from `pathUpdateHandler`, which NWPathMonitor serialises
    /// onto one queue.
    nonisolated(unsafe) private(set) static var isOffline = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            NetworkMonitor.isOffline = !connected
            Task { @MainActor in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }
}
