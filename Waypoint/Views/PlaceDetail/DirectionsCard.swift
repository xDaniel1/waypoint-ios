import SwiftUI

struct DirectionsCard: View {
    @Bindable var viewModel: DirectionsViewModel
    let onClose: () -> Void
    let onStartNavigation: (RouteOption) -> Void

    @State private var pageIndex = 0
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
                if viewModel.mode == .transit {
                    transitList
                } else {
                    pagedRouteCards
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: viewModel.mode)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedRouteID)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isCalculating)
        .onChange(of: pageIndex) { _, i in
            guard viewModel.routeOptions.indices.contains(i) else { return }
            viewModel.select(viewModel.routeOptions[i])
        }
        .onChange(of: viewModel.routeOptions.count) { _, _ in pageIndex = 0 }
        .sheet(isPresented: $showingSteps) {
            if let route = viewModel.selectedRoute {
                RouteStepsSheet(destination: viewModel.destinationTitle, route: route)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Directions").font(.headline)
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

    // MARK: Endpoints

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
                .font(.title3).foregroundStyle(tint).frame(width: 32)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isPlaceholder ? .blue : .primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Drive / Walk / Bike — swipeable paged cards

    private var pagedRouteCards: some View {
        VStack(spacing: 8) {
            TabView(selection: $pageIndex) {
                ForEach(Array(viewModel.routeOptions.enumerated()), id: \.element.id) { index, option in
                    DriveRouteCard(
                        option: option,
                        label: index == 0 ? "Fastest" : shortLabel(option),
                        onGo: {
                            viewModel.select(option)
                            if viewModel.mode == .automobile || viewModel.mode == .walking || viewModel.mode == .cycling {
                                onStartNavigation(option)
                            } else {
                                showingSteps = true
                            }
                        }
                    )
                    .padding(.horizontal, 2)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: viewModel.routeOptions.count > 1 ? .always : .never))
            .frame(height: 150)

            Text("Route and ETA reflect current traffic. Live turn-by-turn guidance is an Apple-private system feature.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func shortLabel(_ option: RouteOption) -> String {
        // Google descriptions look like "via Broadway and Bedford Ave"; keep them short.
        option.summary.replacingOccurrences(of: "via ", with: "via ")
    }

    // MARK: Transit — rich vertical list

    private var transitList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(viewModel.routeOptions.enumerated()), id: \.element.id) { _, option in
                    TransitCard(
                        option: option,
                        isSelected: option.id == viewModel.selectedRoute?.id,
                        onSelect: { viewModel.select(option) },
                        onGo: { viewModel.select(option); showingSteps = true }
                    )
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxHeight: 360)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
    }
}

// MARK: - Drive route card (one page)

private struct DriveRouteCard: View {
    let option: RouteOption
    let label: String
    let onGo: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(option.shortDuration)
                        .font(.title.weight(.bold))
                        .foregroundStyle(option.hasTraffic ? .orange : .primary)
                    if option.hasTraffic {
                        Image(systemName: "car.side.and.exclamationmark").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("\(option.formattedETA) ETA · \(option.formattedDistance)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            GoButton(action: onGo)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Transit card

private struct TransitCard: View {
    let option: RouteOption
    let isSelected: Bool
    let onSelect: () -> Void
    let onGo: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.shortDuration).font(.title3.weight(.semibold))
                            if let fare = option.fare {
                                Text(fare)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        if let dep = option.departureText {
                            Text("\(dep) · \(option.formattedETA) ETA")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    GoButton(action: onGo)
                }
                TransitLegRow(legs: option.transitLegs)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.blue : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TransitLegRow: View {
    let legs: [DirectionsLeg]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    switch leg {
                    case .walk(let minutes):
                        HStack(spacing: 1) {
                            Image(systemName: "figure.walk").font(.caption)
                            Text("\(minutes)").font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    case .transit(let step):
                        HStack(spacing: 4) {
                            LineBadge(step: step)
                            Image(systemName: step.vehicleSymbol).font(.caption)
                        }
                    }
                }
            }
        }
    }
}

private struct LineBadge: View {
    let step: TransitStep

    var body: some View {
        let bg = Color(hex: step.color) ?? .blue
        Text(step.displayLine)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, step.isSubway ? 0 : 7)
            .frame(minWidth: step.isSubway ? 22 : nil, minHeight: 22)
            .frame(height: 22)
            .background(bg, in: step.isSubway ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
    }
}

// MARK: - Shared

private struct GoButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("GO")
                .font(.headline).foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(.green, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("goButton")
    }
}

private struct ModeButton: View {
    let mode: DirectionsViewModel.Mode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(action: action) { icon }.buttonStyle(.glassProminent)
            } else {
                Button(action: action) { icon }.buttonStyle(.glass)
            }
        }
        .accessibilityIdentifier(mode.label)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: some View {
        Image(systemName: mode.symbolName)
            .font(.system(size: 18))
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .accessibilityHidden(true)
    }
}

// MARK: - Steps sheet

private struct RouteStepsSheet: View {
    let destination: String
    let route: RouteOption
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.shortDuration).font(.title2.weight(.semibold))
                        Text("\(route.formattedETA) ETA · \(route.formattedDistance)")
                            .font(.caption).foregroundStyle(.secondary)
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
                                Image(systemName: "arrow.turn.up.right").foregroundStyle(.blue).frame(width: 24)
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
