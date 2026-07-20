import SwiftUI

/// Bottom Liquid Glass capsule during navigation: arrival / min / mi. Tap or drag up to reveal
/// the actions panel (Add Stop, Share ETA, Report Incident, End Route).
struct NavigationBottomBar: View {
    let arrival: String
    let minutes: String
    let distance: String
    let destinationName: String
    let onEndRoute: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 12) {
            if isExpanded {
                expandedContent
            } else {
                summaryRow
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -30 { isExpanded = true }
                    else if value.translation.height > 30 { isExpanded = false }
                }
        )
    }

    private var summaryRow: some View {
        HStack {
            stat(value: arrival, label: "arrival")
            Spacer()
            stat(value: minutes, label: "min")
            Spacer()
            stat(value: distance, label: "mi")
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title.weight(.bold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 12) {
            summaryRow
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.red).font(.title2)
                Text(destinationName).font(.body).lineLimit(2)
                Spacer()
            }
            .padding(.vertical, 4)
            Button(action: onEndRoute) {
                Text("End Route")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }
}
