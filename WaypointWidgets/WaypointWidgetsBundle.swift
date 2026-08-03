import SwiftUI
import WidgetKit

@main
struct WaypointWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextDestinationWidget()
        NavigationLiveActivityWidget()
    }
}
