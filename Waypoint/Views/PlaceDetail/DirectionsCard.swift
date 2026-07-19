import SwiftUI

struct DirectionsCard: View {
    @Bindable var viewModel: DirectionsViewModel
    let onClose: () -> Void

    @State private var showingSteps = false

    var body: some View {
        VStack(spacing: 14) {
            header
            modePicker
            endpointsCard

            if viewModel.isCalculating {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let errorMessage = viewModel.errorMessage {
                errorView(errorMessage)
            } else if !viewModel.routeOptions.isEmpty {
                alternatesList
                primaryBar
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: viewModel.mode)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedRouteID)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isCalculating)
        .sheet(isPresented: $showingSteps) {
            if let route = viewModel.selectedRoute {
                RouteStepsSheet(destination: viewModel.destinationTitle, route: route)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Directions")
                .font(.headline)
            HStack {
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
    }

    // MARK: Modes (icon-only, like Apple Maps)

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

    // MARK: From / To / Add Stop

    private var endpointsCard: some View {
        VStack(spacing: 0) {
            endpointRow(icon: "location.fill", tint: .blue, text: "My Location", isPlaceholder: false)
            Divider().padding(.leading, 44)
            endpointRow(icon: "mappin.circle.fill", tint: .red, text: viewModel.destinationTitle, isPlaceholder: false)
            Divider().padding(.leading, 44)
            endpointRow(icon: "plus.circle.fill", tint: .blue, text: "Add Stop", isPlaceholder: true)
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func endpointRow(icon: String, tint: Color, text: String, isPlaceholder: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isPlaceholder ? .blue : .primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Alternate routes

    @ViewBuilder
    private var alternatesList: some View {
        if viewModel.routeOptions.count > 1 {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(viewModel.routeOptions.enumerated()), id: \.element.id) { index, option in
                        RouteRow(
                            option: option,
                            label: index == 0 ? "Fastest" : "Alternate \(index)",
                            isSelected: option.id == viewModel.selectedRoute?.id,
                            isTransit: viewModel.mode == .transit
                        ) {
                            viewModel.select(option)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    // MARK: Primary summary bar with GO

    @ViewBuilder
    private var primaryBar: some View {
        if let route = viewModel.selectedRoute {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(route.shortDuration)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(route.hasTraffic ? .orange : .primary)
                        if route.hasTraffic {
                            Image(systemName: "car.side.and.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("\(route.formattedETA) ETA · \(route.formattedDistance)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingSteps = true
                } label: {
                    Text("GO")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(.green, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goButton")
            }
        }
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

// MARK: - Alternate route row

private struct RouteRow: View {
    let option: RouteOption
    let label: String
    let isSelected: Bool
    let isTransit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? Color.blue : .secondary)
                    Text(option.shortDuration)
                        .font(.headline)
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
                isSelected ? .regular.tint(.blue.opacity(0.22)) : .regular,
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
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: vehicleSymbol(step.vehicle)).font(.caption2)
                        Text(step.displayLine).font(.caption.weight(.semibold))
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
        case let v where v.contains("FERRY") || v.contains("BOAT"): "ferry.fill"
        default: "tram.fill"
        }
    }
}

// MARK: - Mode button

private struct ModeButton: View {
    let mode: DirectionsViewModel.Mode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(action: action) { icon }
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action) { icon }
                    .buttonStyle(.glass)
            }
        }
        .accessibilityIdentifier(mode.label)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: some View {
        Image(systemName: mode.symbolName)
            .font(.system(size: 18))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .accessibilityHidden(true)
    }
}

// MARK: - Steps sheet (in-app, honest about no live voice nav)

private struct RouteStepsSheet: View {
    let destination: String
    let route: RouteOption
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(route.shortDuration).font(.title2.weight(.semibold))
                            Text("\(route.formattedETA) ETA · \(route.formattedDistance)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                if route.steps.isEmpty {
                    Section {
                        Text("Turn-by-turn steps aren't available for this route.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Steps") {
                        ForEach(route.steps) { step in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "arrow.turn.up.right")
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.instruction).font(.subheadline)
                                    Text(step.formattedDistance).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section {
                    Text("Waypoint shows the full step list and live-traffic ETA in-app. Spoken turn-by-turn guidance is an Apple-private system feature.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("To \(destination)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
