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

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }
}
