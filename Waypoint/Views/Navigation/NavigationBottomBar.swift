import SwiftUI

/// Bottom navigation card. Collapsed it's just arrival / min / mi; dragging or tapping expands it
/// into the destination row plus Add Stop, Share ETA, Report an Incident, Voice Controls, and
/// End Route — matching Apple Maps' navigation sheet.
struct NavigationBottomBar: View {
    let arrival: String
    let minutes: String
    let distance: String
    let destinationName: String
    var destinationPhone: String?
    var isMuted: Bool = false
    let onEndRoute: () -> Void
    var onAddStop: () -> Void = {}
    var onShareETA: () -> Void = {}
    var onReportIncident: () -> Void = {}
    var onToggleMute: () -> Void = {}
    /// Reports the card's rendered height so the floating map buttons can sit right above it.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @State private var isExpanded = false
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)

            summaryRow
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, isExpanded ? 14 : 18)

            if isExpanded {
                expandedContent
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth(duration: 0.35)) { isExpanded.toggle() }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in dragTranslation = value.translation.height }
                .onEnded { value in
                    withAnimation(.smooth(duration: 0.35)) {
                        if value.translation.height < -40 { isExpanded = true }
                        else if value.translation.height > 40 { isExpanded = false }
                        dragTranslation = 0
                    }
                }
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            onHeightChange(newValue)
        }
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
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 12) {
            destinationRow

            VStack(spacing: 0) {
                actionRow(icon: "plus", tint: .blue, title: "Add Stop", action: onAddStop)
                Divider().padding(.leading, 56)
                actionRow(icon: "person.crop.circle.badge.plus", tint: .green, title: "Share ETA", action: onShareETA)
                Divider().padding(.leading, 56)
                actionRow(icon: "exclamationmark.bubble.fill", tint: .red, title: "Report an Incident", action: onReportIncident)
                Divider().padding(.leading, 56)
                actionRow(
                    icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    tint: .secondary,
                    title: isMuted ? "Sound Off" : "Sound On",
                    action: onToggleMute
                )
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

            Button(action: onEndRoute) {
                Text("End Route")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.red, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("endRouteButton")
        }
    }

    private var destinationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white, .pink)
            Text(destinationName)
                .font(.title3)
                .lineLimit(1)
            Spacer()
            if let phone = destinationPhone, let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.blue)
                        .frame(width: 38, height: 38)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func actionRow(icon: String, tint: Color, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(tint)
                    .frame(width: 30)
                Text(title)
                    .font(.title3)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
