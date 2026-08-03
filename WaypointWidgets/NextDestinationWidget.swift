import SwiftUI
import WidgetKit

/// Honest scope: this shows the destination/ETA of a trip that's *currently active* in the app
/// (published via `NavigationWidgetDataStore` when navigation starts/updates/ends), not a
/// predicted "where you're probably headed next" — that kind of on-device prediction is a
/// private Apple/Siri capability, not something a third-party app can honestly replicate.
struct NextDestinationEntry: TimelineEntry {
    let date: Date
    let snapshot: NavigationWidgetDataStore.TripSnapshot?
}

struct NextDestinationProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextDestinationEntry {
        NextDestinationEntry(
            date: .now,
            snapshot: .init(destinationName: "Golden Gate Park", arrivalDate: .now.addingTimeInterval(600), remainingMinutes: 10)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextDestinationEntry) -> Void) {
        completion(NextDestinationEntry(date: .now, snapshot: NavigationWidgetDataStore.currentSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextDestinationEntry>) -> Void) {
        let entry = NextDestinationEntry(date: .now, snapshot: NavigationWidgetDataStore.currentSnapshot())
        // The app force-reloads this widget's timeline on every real change (trip start/update/
        // end), so this fallback refresh only matters if that ever gets missed — frequent during
        // an active trip so the ETA doesn't visibly go stale, rare otherwise.
        let nextRefresh: Date = entry.snapshot == nil ? .now.addingTimeInterval(3600) : .now.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct NextDestinationWidgetView: View {
    let entry: NextDestinationEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(snapshot.destinationName).font(.headline).lineLimit(1)
                } icon: {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                }
                Spacer(minLength: 4)
                Text(snapshot.arrivalDate, style: .time)
                    .font(.title2.weight(.semibold))
                Text("\(snapshot.remainingMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "location.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No active trip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct NextDestinationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NavigationWidgetDataStore.widgetKind, provider: NextDestinationProvider()) { entry in
            NextDestinationWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Destination")
        .description("Shows your active trip's destination and ETA.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
