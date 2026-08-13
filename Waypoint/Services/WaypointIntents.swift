import AppIntents
import CoreLocation
import Foundation
import MapKit

/// Siri and Shortcuts entry points.
///
/// Apple Maps answers "directions to work" from anywhere in the system; without these the app was
/// only reachable by opening it. Each intent opens the app and hands off to the same routing path
/// the UI uses, rather than duplicating logic.
struct GetDirectionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Directions"
    static let description = IntentDescription("Start directions to a place in Waypoint.")
    /// Routing needs the map, so this always brings the app forward.
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Destination", requestValueDialog: "Where do you want to go?")
    var destination: String

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.shared.request = .directions(query: destination)
        return .result()
    }
}

struct SearchNearbyIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Nearby"
    static let description = IntentDescription("Search for places near you in Waypoint.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.shared.request = .search(query: query)
        return .result()
    }
}

/// Handed from an intent to `MapScreen`, which picks it up on the next appearance. The intent
/// itself can't drive the UI directly — it runs before the scene is necessarily ready.
@Observable
@MainActor
final class PendingIntent {
    static let shared = PendingIntent()

    enum Request: Equatable {
        case search(query: String)
        case directions(query: String)
    }

    var request: Request?

    private init() {}
}

struct WaypointShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetDirectionsIntent(),
            // Only AppEntity/AppEnum parameters can be interpolated into a phrase, so the
            // destination is asked for via `requestValueDialog` instead of spoken inline.
            phrases: [
                "Get directions with \(.applicationName)",
                "Directions with \(.applicationName)",
                "Navigate with \(.applicationName)"
            ],
            shortTitle: "Directions",
            systemImageName: "arrow.triangle.turn.up.right.circle.fill"
        )
        AppShortcut(
            intent: SearchNearbyIntent(),
            phrases: [
                "Search with \(.applicationName)",
                "Find a place with \(.applicationName)"
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}
