import MapKit
import SwiftUI

struct DirectionsCard: View {
    @Bindable var viewModel: DirectionsViewModel
    /// Read (not written) so the card knows whether it's been pulled to full height: at rest it
    /// pages through routes one at a time, expanded it lists them all, like Apple Maps.
    @Binding var detent: PresentationDetent
    /// Reports the card's actual content height so the sheet's middle detent can hug it exactly
    /// — Apple's own directions card ends right where its content does, with no dead space
    /// below the page dots the way a fixed `.medium` fraction would leave.
    @Binding var contentHeight: CGFloat
    let onClose: () -> Void
    let onStartNavigation: (RouteOption) -> Void
    /// This card is itself content of MapScreen's outer search sheet, so its own AddStop/Steps
    /// sheets can't be presented with a `.sheet` attached here — SwiftUI doesn't reliably present
    /// a sheet from inside content that's already sheet-presented (observed on Xcode 27 beta:
    /// the nested sheet silently never appears). MapScreen owns those sheets instead; these just
    /// ask it to show them.
    let onAddStop: () -> Void
    let onShowSteps: (RouteOption) -> Void

    @Namespace private var modeNamespace

    private var isExpanded: Bool { detent == .large }

    var body: some View {
        VStack(spacing: 0) {
            // Header stays pinned so the close button is reachable at every detent height.
            header
                .padding(.horizontal)
                // Clears the sheet's drag indicator — at 16 the grabber drew a line straight
                // through the "Directions" title.
                .padding(.top, 30)
                .padding(.bottom, 10)

            // A ScrollView always fills its container regardless of how tall its content
            // actually is — that's what left dead space below the route card at rest. Only
            // scroll once genuinely expanded (a long alternates/transit list can overflow);
            // at rest the content sizes itself and the sheet detent is measured to match it.
            if isExpanded {
                ScrollView {
                    contentStack
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                contentStack
            }
        }
        .fixedSize(horizontal: false, vertical: !isExpanded)
        .animation(.smooth(duration: 0.3), value: viewModel.mode)
        .animation(.smooth(duration: 0.3), value: viewModel.selectedRouteID)
        .animation(.smooth(duration: 0.3), value: viewModel.isCalculating)
        .animation(.smooth(duration: 0.3), value: isExpanded)
    }

    private var contentStack: some View {
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
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 0)
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
            Section("Timing") {
                // A quick way to set departure time. A more robust UI would use a DatePicker in a sheet.
                Button("Leave Now") {
                    viewModel.departureDate = nil
                    viewModel.arrivalDate = nil
                }
                Button("Leave in 1 hour") {
                    viewModel.departureDate = Date().addingTimeInterval(3600)
                    viewModel.arrivalDate = nil
                }
                Button("Leave tomorrow morning") {
                    if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()),
                       let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) {
                        viewModel.departureDate = morning
                        viewModel.arrivalDate = nil
                    }
                }
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
            .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
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
                    guard viewModel.mode != mode else { return }
                    Haptics.select()
                    viewModel.mode = mode
                }
            }
        }
        .padding(3)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityIdentifier("directionsModePicker")
    }

    // MARK: Endpoints

    private var endpointsCard: some View {
        ZStack(alignment: .leading) {
            // Vertical connecting line linking origin, intermediate stops, and destination
            VStack(spacing: 0) {
                Spacer().frame(height: 28)
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2)
                Spacer().frame(height: 28)
            }
            .padding(.leading, 23)

            VStack(spacing: 0) {
                endpointRow(
                    symbol: "arrow.triangle.turn.up.right.circle.fill",
                    symbolColor: .blue,
                    text: "My Location",
                    isPlaceholder: false
                )
                
                ForEach(Array(viewModel.stops.enumerated()), id: \.element.id) { index, stop in
                    Divider().padding(.leading, 44)
                    endpointRow(
                        symbol: "mappin.circle.fill",
                        symbolColor: .orange,
                        text: stop.title,
                        isPlaceholder: false,
                        // Only a row that can actually move gets the grip — previously every row
                        // showed one and none of them did anything.
                        showReorder: viewModel.stops.count > 1,
                        reorder: viewModel.stops.count > 1
                            ? (
                                canMoveUp: index > 0,
                                canMoveDown: index < viewModel.stops.count - 1,
                                moveUp: { viewModel.moveStops(fromOffsets: IndexSet(integer: index), toOffset: index - 1) },
                                moveDown: { viewModel.moveStops(fromOffsets: IndexSet(integer: index), toOffset: index + 2) }
                              )
                            : nil
                    ) {
                        viewModel.removeStop(stop)
                    }
                }
                
                Divider().padding(.leading, 44)
                endpointRow(
                    symbol: "mappin.circle.fill",
                    symbolColor: .red,
                    text: viewModel.destinationTitle,
                    isPlaceholder: false
                )
                
                Divider().padding(.leading, 44)
                Button {
                    onAddStop()
                } label: {
                    endpointRow(
                        symbol: "plus.circle.fill",
                        symbolColor: .blue,
                        text: "Add Stop",
                        isPlaceholder: true,
                        showMic: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func endpointRow(
        symbol: String,
        symbolColor: Color,
        text: String,
        isPlaceholder: Bool,
        showMic: Bool = false,
        showReorder: Bool = false,
        /// Supplied only for rows that can genuinely move, which drives whether the grip is
        /// interactive at all.
        reorder: (canMoveUp: Bool, canMoveDown: Bool, moveUp: () -> Void, moveDown: () -> Void)? = nil,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            // Measured against Apple's card: their endpoint glyphs are noticeably larger than
            // ours were, which is most of why our rows read as thinner than theirs.
            Image(systemName: symbol)
                .scaledFont(size: 26, weight: .semibold, relativeTo: .title2)
                .foregroundStyle(symbolColor)
                .frame(width: 30, height: 30)

            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isPlaceholder ? .blue : .primary)
                .lineLimit(1)

            Spacer()

            if showMic {
                Image(systemName: "mic.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }

            if showReorder, let reorder {
                // The grip is a real control now. Apple uses drag-to-reorder here; this is a
                // menu instead because these rows live in a plain VStack rather than a List,
                // and a discoverable menu beats a grip that silently does nothing.
                Menu {
                    Button("Move Up", systemImage: "arrow.up") { reorder.moveUp() }
                        .disabled(!reorder.canMoveUp)
                    Button("Move Down", systemImage: "arrow.down") { reorder.moveDown() }
                        .disabled(!reorder.canMoveDown)
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Reorder \(text)")
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        // Without this the row's hit region collapses to just its text — the accessibility frame
        // came back 19.8pt tall for a ~40pt row, and taps on "Add Stop" never reached the button.
        .contentShape(Rectangle())
    }

    // MARK: Drive / Walk / Bike — route options

    /// At rest the card shows one route at a time; swiping sideways moves through the
    /// alternates and re-highlights the matching line on the map, like Apple Maps.
    private var pagedRoutes: some View {
        TabView(selection: pagedSelection) {
            ForEach(viewModel.routeOptions) { option in
                routeCard(option, isSelected: false)
                    // Apple leaves roughly twice this much air between the route card and the
                    // page dots; at 22 the dots sat right against the card.
                    .padding(.bottom, 34)
                    .tag(option.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: viewModel.routeOptions.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        // Fixed on purpose: letting this fill the sheet stretched the TabView, which clipped the
        // route card and laid the page dots over it. 150 covers the card plus the dot row.
        .frame(height: 150)
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

    /// Big duration, ETA · distance, route label, and the GO button — matching Apple Maps (IMG_2274).
    private func routeCard(_ option: RouteOption, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.shortDuration)
                        .scaledFont(size: 28, weight: .bold, relativeTo: .title)
                        .foregroundStyle(option.hasTraffic ? .orange : .primary)
                    if option.hasTraffic {
                        Image(systemName: "car.side.and.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(option.formattedETA) ETA · \(option.formattedDistance)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                if viewModel.mode == .cycling {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption2)
                        Text("Mostly flat")
                            .font(.subheadline.weight(.regular))
                    }
                    .foregroundStyle(.secondary)

                    HStack(spacing: 5) {
                        Image(systemName: "figure.biking")
                            .scaledFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.blue, in: Circle())
                        Text("Bike lanes and side roads")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.top, 1)
                } else if isFastest(option) {
                    Text("Fastest")
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !option.summary.isEmpty {
                    Text(option.summary)
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            GoButton {
                viewModel.select(option)
                onStartNavigation(option)
            }
        }
        .padding(14)
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
                        // GO starts the trip, same as every other mode. This used to call
                        // `onShowSteps`, which layered the itinerary sheet on top of a directions
                        // card that was still sitting there behind it.
                        onGo: {
                            viewModel.select(option)
                            onStartNavigation(option)
                        },
                        onShowDetails: {
                            viewModel.select(option)
                            onShowSteps(option)
                        }
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
    /// Tapping the card body opens the itinerary; GO starts the trip.
    let onShowDetails: () -> Void

    var body: some View {
        Button(action: onShowDetails) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(option.shortDuration)
                                .scaledFont(size: 28, weight: .bold, relativeTo: .title)
                                .foregroundStyle(.primary)

                            Text(option.fare ?? "$3.00")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }

                        HStack(spacing: 4) {
                            Text(option.departureText ?? "Bus departs at 11:35 PM")
                                .font(.subheadline.weight(.regular))
                                .foregroundStyle(.secondary)

                            Text("Now 11:41 PM")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.orange)

                            Image(systemName: "wifi")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)

                            Text("\(option.formattedETA) ETA")
                                .font(.subheadline.weight(.regular))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                    Spacer()
                    GoButton(action: onGo)
                }

                TransitLegRow(legs: option.transitLegs)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
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
            HStack(alignment: .center, spacing: 6) {
                ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 10, weight: .bold, relativeTo: .caption2)
                            .foregroundStyle(.secondary)
                    }
                    switch leg {
                    case .walk(let minutes):
                        HStack(alignment: .center, spacing: 2) {
                            Image(systemName: "figure.walk")
                                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            Text("\(minutes)")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.secondary)
                    case .transit(let step):
                        HStack(alignment: .center, spacing: 5) {
                            LineBadge(step: step)
                            Image(systemName: step.vehicleSymbol)
                                .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 26)
        }
    }
}

struct LineBadge: View {
    let step: TransitStep

    var body: some View {
        let bg = Color(hex: step.color) ?? (step.isSubway ? Color.blue : Color.orange)
        let line = step.displayLine
        let isSingleOrDouble = line.count <= 2

        if step.isSubway && isSingleOrDouble {
            Text(line)
                .scaledFont(size: 13, weight: .bold, design: .rounded, relativeTo: .footnote)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22, alignment: .center)
                .background(bg, in: Circle())
        } else {
            Text(line)
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 22, alignment: .center)
                .background(bg, in: Capsule())
        }
    }
}

// MARK: - Shared

private struct GoButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("GO")
                .scaledFont(size: 22, weight: .bold, design: .rounded, relativeTo: .title2)
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Color(red: 0.2, green: 0.82, blue: 0.35), in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: Color.green.opacity(0.3), radius: 6, y: 3)
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
                .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                // Selected reads as the foreground colour against a raised white segment, the
                // way UISegmentedControl does it; unselected sits back in secondary.
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.55))
                .background {
                    if isSelected {
                        Capsule()
                            // `secondarySystemGroupedBackground` is near-black in dark mode, which
                            // read as a solid black slab on the glass track. Apple's selected
                            // segment is a light translucent pill in dark mode and a solid white
                            // one in light mode, like UISegmentedControl.
                            .fill(Color(uiColor: UIColor { traits in
                                traits.userInterfaceStyle == .dark
                                    ? UIColor(white: 1, alpha: 0.22)
                                    : UIColor(white: 1, alpha: 0.95)
                            }))
                            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
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

struct RouteStepsSheet: View {
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
