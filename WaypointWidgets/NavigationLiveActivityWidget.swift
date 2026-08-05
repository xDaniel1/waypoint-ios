import ActivityKit
import SwiftUI
import WidgetKit

struct NavigationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "location.north.line.fill")
                        .foregroundStyle(.blue)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.arrivalDate, style: .time).font(.headline)
                        Text("\(context.state.remainingMinutes) min").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.currentInstruction)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "location.north.line.fill").foregroundStyle(.blue)
            } compactTrailing: {
                Text("\(context.state.remainingMinutes)m")
            } minimal: {
                Image(systemName: "location.north.line.fill").foregroundStyle(.blue)
            }
        }
    }

    private func lockScreenView(context: ActivityViewContext<NavigationActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(context.attributes.destinationName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(context.state.arrivalDate, style: .time)
                    .font(.headline)
            }
            Text(context.state.currentInstruction)
                .font(.subheadline)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text("\(context.state.remainingMinutes) min")
                Text("·")
                Text(context.state.remainingDistanceText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.8))
        .activitySystemActionForegroundColor(Color.white)
    }
}
