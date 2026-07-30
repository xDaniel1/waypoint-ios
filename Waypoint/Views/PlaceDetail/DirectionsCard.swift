import SwiftUI

struct DirectionsCard: View {
    @Bindable var viewModel: DirectionsViewModel
    let onClose: () -> Void
    let onStartNavigation: (RouteOption) -> Void

    @State private var showingSteps = false
    @Namespace private var modeNamespace

    var body: some View {
        VStack(spacing: 0) {
            // Header stays pinned so the close button is reachable at every detent height.
            header
                .padding(.horizontal)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 14) {
                    modePicker
                    endpointsCard
                    optionsRow

                    if viewModel.isCalculating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else if let errorMessage = viewModel.errorMessage {
                        errorView(errorMessage)
                    } else if !viewModel.routeOptions.isEmpty {
                        if viewModel.mode == .transit {
                            transitList
                        } else if let selected = viewModel.selectedRoute {
                            selectedRouteBar(selected)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.smooth(duration: 0.3), value: viewModel.mode)
        .animation(.smooth(duration: 0.3), value: viewModel.selectedRouteID)
        .animation(.smooth(duration: 0.3), value: viewModel.isCalculating)
        .sheet(isPresented: $showingSteps) {
            if let route = viewModel.selectedRoute {
                RouteStepsSheet(destination: viewModel.destinationTitle, route: route)
            }
        }
    }

    // MARK: Header

    /// Share on the left, title + Options in the middle, close on the right — the same header
    /// Apple Maps keeps pinned whether the directions card is collapsed or expanded.
    private var header: some View {
        HStack(spacing: 12) {
            ShareLink(item: shareSummary) {
                headerCircleIcon("square.and.arrow.up")
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            VStack(spacing: 3) {
                Text("Directions")
                    .font(.headline)
                Text("Options")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: Capsule())
            }
            .fixedSize()

            Spacer(minLength: 0)

            Button(action: onClose) {
                headerCircleIcon("xmark")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeDirectionsButton")
        }
    }

    private func headerCircleIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(.thickMaterial, in: Circle())
    }

    private var shareSummary: String {
        if let route = viewModel.selectedRoute {
            return "\(viewModel.destinationTitle) — \(route.shortDuration), \(route.formattedDistance)"
        }
        return viewModel.destinationTitle
    }

    /// One continuous pill housing all the mode icons, with a sliding dark highlight behind the
    /// selected one — matching Apple Maps' segmented mode control instead of separate chips.
    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(DirectionsViewModel.Mode.allCases, id: \.self) { mode in
                ModeButton(mode: mode, isSelected: viewModel.mode == mode, namespace: modeNamespace) {
                    viewModel.mode = mode
                }
            }
        }
        .padding(4)
        .background(.thickMaterial, in: Capsule())
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

    // MARK: Options row ("Now" departure · "Avoid" preferences)

    private var optionsRow: some View {
        HStack(spacing: 10) {
            Menu {
                Text("Routes and ETAs use live traffic for right now. Scheduled departure isn't supported yet.")
            } label: {
                optionPill(title: "Now", isActive: false)
            }

            Menu {
                Toggle("Tolls", isOn: $viewModel.avoidTolls)
                Toggle("Highways", isOn: $viewModel.avoidHighways)
                Toggle("Ferries", isOn: $viewModel.avoidFerries)
                if viewModel.mode != .automobile {
                    Section {
                        Text("Avoid options apply to driving routes.")
                    }
                }
            } label: {
                optionPill(title: viewModel.avoidSummary, isActive: viewModel.hasAvoidPreferences)
            }
            .accessibilityIdentifier("avoidMenu")

            Spacer()
        }
    }

    private func optionPill(title: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Image(systemName: "chevron.down").font(.caption2)
        }
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thickMaterial), in: Capsule())
    }

    // MARK: Drive / Walk / Bike — selected-route summary bar

    /// The bottom bar for the currently-selected route (chosen via the map's tappable time
    /// bubbles). Big duration, ETA · distance, route label, and the GO button — like Apple Maps.
    private func selectedRouteBar(_ option: RouteOption) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
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
                Text(isFastest(option) ? "Fastest route, now" : option.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            GoButton {
                viewModel.select(option)
                onStartNavigation(option)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }

    private func isFastest(_ option: RouteOption) -> Bool {
        viewModel.routeOptions.first?.id == option.id
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
        .frame(maxHeight: .infinity)
        .scrollIndicators(.hidden)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
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
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : .primary)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.primary)
                            .matchedGeometryEffect(id: "modeHighlight", in: namespace)
                    }
                }
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(mode.label)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
