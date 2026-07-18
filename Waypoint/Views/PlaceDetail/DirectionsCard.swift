import SwiftUI

struct DirectionsCard: View {
    @Bindable var viewModel: DirectionsViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            modePicker

            if viewModel.isCalculating {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if let errorMessage = viewModel.errorMessage {
                errorView(errorMessage)
            } else if !viewModel.routeOptions.isEmpty {
                routesList
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: viewModel.mode)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedRouteID)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Directions")
                    .font(.title2.weight(.semibold))
                Text("To \(viewModel.destinationTitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeDirectionsButton")
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(DirectionsViewModel.Mode.allCases, id: \.self) { mode in
                ModeButton(mode: mode, isSelected: viewModel.mode == mode) {
                    viewModel.mode = mode
                }
            }
        }
        .accessibilityIdentifier("directionsModePicker")
    }

    private var routesList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(viewModel.routeOptions.enumerated()), id: \.element.id) { index, option in
                    RouteRow(
                        option: option,
                        label: routeLabel(index: index),
                        isSelected: option.id == viewModel.selectedRoute?.id,
                        isTransit: viewModel.mode == .transit
                    ) {
                        viewModel.select(option)
                    }
                }

                Text("Route and ETA shown in-app. Live turn-by-turn guidance is an Apple-private system feature.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.bottom, 12)
        }
    }

    private func routeLabel(index: Int) -> String {
        if viewModel.routeOptions.count <= 1 { return "Route" }
        return index == 0 ? "Fastest" : "Alternate \(index)"
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct RouteRow: View {
    let option: RouteOption
    let label: String
    let isSelected: Bool
    let isTransit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isSelected ? Color.blue : .secondary)
                        Text(option.formattedDuration)
                            .font(.title3.weight(.semibold))
                    }
                    Spacer()
                    Text(option.formattedDistance)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isTransit, !option.transitSteps.isEmpty {
                    transitLine
                } else {
                    Text(option.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isSelected ? .regular.tint(.blue.opacity(0.25)) : .regular,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.blue : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var transitLine: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(option.transitSteps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: vehicleSymbol(step.vehicle))
                            .font(.caption2)
                        Text(step.displayLine)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2), in: Capsule())
                }
            }
        }
    }

    private func vehicleSymbol(_ vehicle: String) -> String {
        switch vehicle.uppercased() {
        case let v where v.contains("BUS"): "bus.fill"
        case let v where v.contains("SUBWAY") || v.contains("METRO") || v.contains("RAIL") || v.contains("TRAIN"): "tram.fill"
        case let v where v.contains("FERRY") || v.contains("BOAT"): "ferry.fill"
        default: "tram.fill"
        }
    }
}

private struct ModeButton: View {
    let mode: DirectionsViewModel.Mode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(action: action) { label }
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
            }
        }
        .accessibilityIdentifier(mode.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        VStack(spacing: 3) {
            Image(systemName: mode.symbolName)
                .font(.system(size: 15))
            Text(mode.label)
                .font(.caption2.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
