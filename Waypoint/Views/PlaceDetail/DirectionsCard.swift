import MapKit
import SwiftUI

struct DirectionsCard: View {
    @Bindable var viewModel: DirectionsViewModel
    /// Read (not written) so the card knows whether it's been pulled to full height: at rest it
    /// pages through routes one at a time, expanded it lists them all, like Apple Maps.
    @Binding var detent: PresentationDetent
    let onClose: () -> Void
    let onStartNavigation: (RouteOption) -> Void

    @State private var showingSteps = false
    @State private var isAddingStop = false
    @Namespace private var modeNamespace

    private var isExpanded: Bool { detent == .large }

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

                    if viewModel.isCalculating {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else if let errorMessage = viewModel.errorMessage {
                        errorView(errorMessage)
                    } else if !viewModel.routeOptions.isEmpty {
                        if viewModel.mode == .transit {
                            transitList
                        } else if isExpanded {
                            routeList
                        } else {
                            pagedRoutes
                                // The page dots sit near the bottom of the pager's own fixed
                                // frame, so without this they read as jammed against the sheet's
                                // bottom edge — Apple Maps leaves real breathing room below them.
                                .padding(.bottom, 24)
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
        .animation(.smooth(duration: 0.3), value: isExpanded)
        .sheet(isPresented: $showingSteps) {
            if let route = viewModel.selectedRoute {
                RouteStepsSheet(destination: viewModel.destinationTitle, route: route)
            }
        }
        .sheet(isPresented: $isAddingStop) {
            AddStopSheet(currentRegion: originRegion) { item in
                viewModel.addStop(item)
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
                optionsMenu
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

    /// Apple keeps route preferences behind the "Options" chip under the title rather than as a
    /// row in the card. The chip names the active preference so it's obvious when one is on.
    private var optionsMenu: some View {
        Menu {
            Section("Avoid on driving routes") {
                Toggle("Tolls", isOn: $viewModel.avoidTolls)
                Toggle("Highways", isOn: $viewModel.avoidHighways)
                Toggle("Ferries", isOn: $viewModel.avoidFerries)
            }
            Section {
                Text("Routes and ETAs use live traffic for right now. Scheduled departure isn't supported yet.")
            }
        } label: {
            Text(viewModel.hasAvoidPreferences ? viewModel.avoidSummary : "Options")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.15), in: Capsule())
        }
        .accessibilityIdentifier("avoidMenu")
    }

    private func headerCircleIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(.thickMaterial, in: Circle())
    }

    private var originRegion: MKCoordinateRegion? {
        guard let coordinate = viewModel.originCoordinate else { return nil }
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)
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
            ForEach(viewModel.stops) { stop in
                Divider().padding(.leading, 44)
                endpointRow(icon: "mappin.circle.fill", tint: .orange, text: stop.title, isPlaceholder: false) {
                    viewModel.removeStop(stop)
                }
            }
            Divider().padding(.leading, 44)
            endpointRow(icon: "mappin.circle.fill", tint: .red, text: viewModel.destinationTitle, isPlaceholder: false)
            Divider().padding(.leading, 44)
            Button {
                isAddingStop = true
            } label: {
                endpointRow(icon: "plus.circle.fill", tint: .blue, text: "Add Stop", isPlaceholder: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func endpointRow(
        icon: String, tint: Color, text: String, isPlaceholder: Bool, onRemove: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(tint).frame(width: 32)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isPlaceholder ? .blue : .primary)
                .lineLimit(1)
            Spacer()
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Drive / Walk / Bike — route options

    /// At rest the card shows one route at a time; swiping sideways moves through the
    /// alternates and re-highlights the matching line on the map, like Apple Maps.
    private var pagedRoutes: some View {
        TabView(selection: pagedSelection) {
            ForEach(viewModel.routeOptions) { option in
                routeCard(option, isSelected: false)
                    .padding(.bottom, 30) // room for the page dots
                    .tag(option.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: viewModel.routeOptions.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .frame(height: 158)
        .accessibilityIdentifier("routePager")
    }

    /// Swiping the pager is the same act as picking that route, so it drives the map selection.
    private var pagedSelection: Binding<RouteOption.ID> {
        Binding(
            get: { viewModel.selectedRoute?.id ?? viewModel.routeOptions.first?.id ?? UUID() },
            set: { newValue in
                guard let option = viewModel.routeOptions.first(where: { $0.id == newValue }) else { return }
                viewModel.select(option)
            }
        )
    }

    /// Pulled to full height, every alternate is listed at once with the selected one outlined.
    private var routeList: some View {
        VStack(spacing: 12) {
            ForEach(viewModel.routeOptions) { option in
                Button {
                    viewModel.select(option)
                } label: {
                    routeCard(option, isSelected: option.id == viewModel.selectedRoute?.id)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("routeList")
    }

    /// Big duration, ETA · distance, route label, and the GO button — like Apple Maps.
    private func routeCard(_ option: RouteOption, isSelected: Bool) -> some View {
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
                if isFastest(option) {
                    Text("Fastest")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !option.summary.isEmpty {
                    Text(option.summary)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
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
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isSelected ? Color.blue : .clear, lineWidth: 2)
        )
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
                    Text("Tap GO to start turn-by-turn navigation with spoken directions.")
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
