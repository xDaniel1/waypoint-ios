import Foundation
import OSLog

/// Shared log categories. `print` doesn't reliably reach the unified log for processes launched
/// by the test runner, which made a couple of failures much harder to trace than they needed to
/// be — anything worth keeping should go through here instead.
extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.danielguzman.waypoint"

    /// Google Places lookups and their MapKit fallbacks.
    static let places = Logger(subsystem: subsystem, category: "places")
    /// Speed limit sources (OpenStreetMap, NYC DOT).
    static let speedLimit = Logger(subsystem: subsystem, category: "speed-limit")
    /// Routing and active navigation.
    static let navigation = Logger(subsystem: subsystem, category: "navigation")
}
