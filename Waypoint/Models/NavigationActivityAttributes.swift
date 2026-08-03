import ActivityKit
import Foundation

/// Live Activity data for an active navigation trip. Shared between the main app (which starts/
/// updates/ends the activity from `LiveActivityService`) and the widget extension (which renders
/// it on the Lock Screen and in the Dynamic Island) — this file is compiled into both targets.
/// Kept small on purpose: ActivityKit re-encodes and delivers the whole `ContentState` on every
/// update, so extra fields cost real battery and are rate-limited by the system.
struct NavigationActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var currentInstruction: String
        var remainingMinutes: Int
        var remainingDistanceText: String
        var arrivalDate: Date
    }

    let destinationName: String
}
