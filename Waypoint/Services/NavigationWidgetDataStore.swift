import Foundation
import WidgetKit

/// Persists the active trip's destination/ETA into the shared App Group container so the home
/// screen widget's `TimelineProvider` — running in its own extension process, with no access to
/// the app's in-memory state — can read it. Shared between the main app (writes via `publish`/
/// `clear`) and the widget extension (reads via `currentSnapshot`); this file is compiled into
/// both targets. `reloadTimelines` asks WidgetKit to redraw immediately rather than waiting for
/// the widget's own timeline policy, so the home screen updates within moments of a real change.
enum NavigationWidgetDataStore {
    static let appGroupID = "group.com.danielguzman.waypoint"
    static let widgetKind = "NextDestinationWidget"
    private static let storageKey = "com.danielguzman.waypoint.widget.activeTrip"

    struct TripSnapshot: Codable {
        let destinationName: String
        let arrivalDate: Date
        let remainingMinutes: Int
    }

    static func publish(_ snapshot: TripSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    static func currentSnapshot() -> TripSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(TripSnapshot.self, from: data)
    }
}
