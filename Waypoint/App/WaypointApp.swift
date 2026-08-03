import SwiftUI

@main
struct WaypointApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Registering this here (rather than lazily on first `.shared` access somewhere deep in the
    /// view hierarchy) guarantees MetricKit's subscriber is attached as early in the process
    /// lifecycle as possible, and that the "dirty until proven clean" flag for this launch gets
    /// set immediately.
    private let crashReporting = CrashReportingService.shared

    var body: some Scene {
        WindowGroup {
            MapScreen()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                crashReporting.markCleanShutdown()
            }
        }
    }
}
