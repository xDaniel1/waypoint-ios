import MapKit
import SwiftUI

/// The three states Apple Maps' own location button cycles through: not tracking, centered on
/// the user without rotating the map, and centered while rotating to match device heading.
enum UserTrackingMode {
    case off, follow, followHeading
}

struct MapScreen: View {
    @State private var viewModel = MapViewModel()
    @State private var searchViewModel = SearchViewModel()
    @State private var directionsViewModel = DirectionsViewModel()
    @State private var navigationViewModel = NavigationViewModel()
    @State private var weatherService = WeatherService()
    @State private var hasFetchedWeather = false
    @State private var searchDetent: PresentationDetent = .home
    @State private var collapsedHeight: CGFloat = 90
    @State private var sheetHeight: CGFloat = 90
    @State private var mapStyle: MapStyle = .standard
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var currentCamera: MapCamera?
    @State private var trackingMode: UserTrackingMode = .off
    /// Shared between the GPS-fix and compass-heading update paths so they never both animate
    /// the camera within the same window — that fight was the source of the stutter/snapping.
    @State private var lastCameraAnimation: Date = .distantPast
    @State private var speedLimitService = SpeedLimitService()
    @State private var navBarHeight: CGFloat = 120
    @State private var voiceGuidance = VoiceGuidanceService()
    @State private var isRerouting = false
    @State private var isSearchingAlongRoute = false
    @State private var liveActivity = LiveActivityService()
    /// Live Activity updates are rate-limited by the system and cost real battery, so this
    /// throttles how often a GPS-fix-driven update actually pushes new content — a step-advance
    /// mid-window still feels responsive since the banner/voice already reacted to it.
    @State private var lastLiveActivityUpdate: Date = .distantPast
    /// Set when the user pans/zooms/rotates. While true, nothing programmatically moves the
    /// camera — they stay wherever they dragged to until they tap re-center.
    @State private var isCameraUserControlled = false
    /// A built-in map POI (restaurant, shop, landmark) the user tapped directly on the map.
    @State private var selectedMapFeature: MapFeature?
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            Map(position: $viewModel.cameraPosition, selection: $selectedMapFeature, scope: mapScope) {
                // We draw the location indicator ourselves so it reads like Apple's: a blue dot
                // in a white ring with a heading wedge, and a chevron puck while navigating.
                // MapKit's stock dot picks up the map tint and looks washed out.
                if let location = viewModel.currentLocation {
                    Annotation("", coordinate: location.coordinate) {
                        if navigationViewModel.isActive {
                            NavigationPuck(
                                heading: viewModel.currentHeading ?? (location.course >= 0 ? location.course : 0),
                                headingAccuracy: viewModel.currentHeadingAccuracy ?? 30
                            )
                        } else {
                            UserLocationDot(
                                heading: viewModel.currentHeading,
                                headingAccuracy: viewModel.currentHeadingAccuracy ?? 30
                            )
                        }
                    }
                    .annotationTitles(.hidden)
                } else {
                    UserAnnotation()
                }
                if let result = searchViewModel.selectedResult {
                    Marker(result.title, coordinate: result.coordinate)
                        .tint(.indigo)
                }
                ForEach(directionsViewModel.stops) { stop in
                    Marker(stop.title, coordinate: stop.coordinate)
                        .tint(.orange)
                }
                // Draw alternates first (under), selected route last (on top). Alternates keep a
                // muted blue rather than gray so every option reads as a route you can take.
                ForEach(directionsViewModel.routeOptions) { option in
                    if option.id != directionsViewModel.selectedRoute?.id {
                        MapPolyline(option.polyline)
                            .stroke(Color.blue.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
                if let selected = directionsViewModel.selectedRoute {
                    MapPolyline(selected.polyline)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    // Colored on top of the base line wherever Google's live traffic data says
                    // this stretch is actually slower than free-flow — not just the whole-route
                    // "has traffic" badge.
                    ForEach(selected.congestionSegments) { segment in
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(segment.severity.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(Array(directionsViewModel.routeOptions.enumerated()), id: \.element.id) { index, option in
                    if let mid = option.midCoordinate {
                        Annotation("", coordinate: mid) {
                            RouteTimeBubble(
                                text: option.shortDuration,
                                label: index == 0 ? "Fastest" : nil,
                                isSelected: option.id == directionsViewModel.selectedRoute?.id
                            ) {
                                directionsViewModel.select(option)
                            }
                        }
                        .annotationTitles(.hidden)
                    }
                }
                // Transit stops for the selected transit route.
                if directionsViewModel.mode == .transit, let selected = directionsViewModel.selectedRoute {
                    ForEach(selected.transitStops) { stop in
                        Annotation(stop.name, coordinate: stop.coordinate) {
                            Circle()
                                .fill(.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.blue, lineWidth: 3))
                        }
                    }
                }
                // Active navigation route: dim the traveled portion, keep the road ahead bright.
                if navigationViewModel.isActive {
                    let traveled = navigationViewModel.traveledCoordinates
                    if traveled.count > 1 {
                        MapPolyline(coordinates: traveled)
                            .stroke(Color.blue.opacity(0.35), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    }
                    let remaining = navigationViewModel.remainingCoordinates
                    if remaining.count > 1 {
                        MapPolyline(coordinates: remaining)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    }
                    if let route = navigationViewModel.route {
                        ForEach(route.congestionSegments) { segment in
                            MapPolyline(coordinates: segment.coordinates)
                                .stroke(segment.severity.color, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
            .mapStyle(navigationViewModel.isActive ? .standard(elevation: .realistic) : mapStyle)
            .onMapCameraChange(frequency: .onEnd) { context in
                searchViewModel.updateSearchRegion(context.region)
                mapCenter = context.region.center
                withAnimation(.smooth(duration: 0.35)) {
                    currentCamera = context.camera
                }
            }
            // Any touch on the map hands control back to the user: auto-follow stops re-centering
            // so panning/rotating sticks instead of snapping back, exactly like Apple Maps.
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        if trackingMode != .off { trackingMode = .off }
                        isCameraUserControlled = true
                    }
            )
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .onChanged { _ in
                        if trackingMode != .off { trackingMode = .off }
                        isCameraUserControlled = true
                    }
            )
            .simultaneousGesture(
                RotateGesture(minimumAngleDelta: .degrees(1))
                    .onChanged { _ in
                        if trackingMode != .off { trackingMode = .off }
                        isCameraUserControlled = true
                    }
            )
            .ignoresSafeArea(edges: .top)

            if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
                LocationPermissionDeniedView()
            }

            if !navigationViewModel.isActive {
                mapControlsOverlay
                    .transition(.opacity)
                weatherWidgetOverlay
                    .transition(.opacity)
            }
            if navigationViewModel.isActive {
                navigationOverlay
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: navigationViewModel.isActive)
        .mapScope(mapScope)
        .task {
            viewModel.onLocationUpdate = { location in
                if navigationViewModel.isActive {
                    navigationViewModel.update(with: location)
                    Task { await speedLimitService.refreshIfNeeded(at: location) }
                    if Date().timeIntervalSince(lastLiveActivityUpdate) > 20 {
                        lastLiveActivityUpdate = Date()
                        let arrival = Date().addingTimeInterval(navigationViewModel.remainingTime)
                        let minutes = max(1, Int((navigationViewModel.remainingTime / 60).rounded()))
                        liveActivity.update(
                            instruction: navigationViewModel.currentStep?.instruction ?? navigationViewModel.destinationName,
                            remainingMinutes: minutes,
                            remainingDistanceText: navigationViewModel.formattedRemainingDistance,
                            arrivalDate: arrival
                        )
                        NavigationWidgetDataStore.publish(
                            .init(destinationName: navigationViewModel.destinationName, arrivalDate: arrival, remainingMinutes: minutes)
                        )
                    }
                    // Once the user has panned the map themselves, stop dragging the camera
                    // back to them — they regain control until they tap re-center.
                    guard !isCameraUserControlled else { return }
                    // North-up by default, even while navigating — the map only rotates once
                    // the user explicitly opts in via the location button's heading mode.
                    let heading = trackingMode == .followHeading
                        ? (viewModel.currentHeading ?? (location.course >= 0 ? location.course : 0))
                        : 0
                    animateCamera(duration: 0.9) {
                        viewModel.followUser(at: location, heading: heading)
                    }
                } else if trackingMode == .follow, !isCameraUserControlled {
                    // Recenter without rotating — the map stays north-up, only the dot moves.
                    animateCamera(duration: 0.6) {
                        viewModel.recenterKeepingZoom(on: location, camera: currentCamera)
                    }
                }
                guard !hasFetchedWeather else { return }
                hasFetchedWeather = true
                Task { await weatherService.refresh(for: location) }
            }
            directionsViewModel.onRoutesChanged = { _, selected in
                if let selected {
                    viewModel.fitCamera(toRoute: selected.boundingMapRect)
                }
            }
            navigationViewModel.onAnnouncement = { text in
                voiceGuidance.speak(text)
            }
            // The view model can tell us we've drifted off the path, or that a stop was added
            // mid-trip via search-along-route — either way it doesn't fetch routes itself,
            // that's recomputeActiveRoute()'s job.
            navigationViewModel.onOffRoute = { recomputeActiveRoute() }
            navigationViewModel.onStopAdded = { recomputeActiveRoute() }
            await viewModel.start()
        }
        // Compass-driven camera rotation ONLY applies once the user explicitly opts in via the
        // location button's heading mode (2nd tap) — never automatically, not even while
        // navigating. Otherwise the base map stays fixed and only the blue dot's heading cone
        // moves, matching how iOS itself behaves.
        .onChange(of: viewModel.currentHeading) { _, newHeading in
            guard let newHeading, let location = viewModel.currentLocation else { return }
            guard trackingMode == .followHeading else { return }
            animateCamera(duration: 0.15, linear: true) {
                viewModel.followUser(at: location, heading: newHeading)
            }
        }
        .sheet(isPresented: .constant(!navigationViewModel.isActive)) {
            SearchSheet(
                viewModel: searchViewModel,
                directionsViewModel: directionsViewModel,
                currentLocation: viewModel.currentLocation,
                detent: $searchDetent,
                collapsedHeight: $collapsedHeight,
                sheetHeight: $sheetHeight,
                onStartNavigation: { route in
                    let name = searchViewModel.selectedResult?.title ?? directionsViewModel.destinationTitle
                    // The route's own endpoint is the most reliable destination coordinate —
                    // it's guaranteed to exist for any route that was actually computed, unlike
                    // the search selection, which directionsViewModel.stop() clears right below.
                    let destinationCoordinate = route.coordinates.last
                        ?? searchViewModel.selectedResult?.coordinate
                        ?? viewModel.currentLocation?.coordinate
                        ?? CLLocationCoordinate2D()
                    navigationViewModel.start(
                        route: route,
                        destinationName: name,
                        destinationCoordinate: destinationCoordinate,
                        intermediateStops: directionsViewModel.stops.map(\.coordinate)
                    )
                    let arrival = Date().addingTimeInterval(route.travelTime)
                    let minutes = max(1, Int((route.travelTime / 60).rounded()))
                    liveActivity.start(
                        destinationName: name,
                        instruction: navigationViewModel.currentStep?.instruction ?? "Head to \(name)",
                        remainingMinutes: minutes,
                        remainingDistanceText: navigationViewModel.formattedRemainingDistance,
                        arrivalDate: arrival
                    )
                    NavigationWidgetDataStore.publish(.init(destinationName: name, arrivalDate: arrival, remainingMinutes: minutes))
                    lastLiveActivityUpdate = Date()
                    directionsViewModel.stop()
                    // Starting navigation always takes the camera back, even if the user had
                    // panned away while choosing a route.
                    isCameraUserControlled = false
                    lastCameraAnimation = .distantPast
                    // Zoom straight into the user's pin the moment GO is tapped, instead of
                    // waiting for the next GPS fix to snap the camera into follow-mode.
                    if let location = viewModel.currentLocation {
                        let heading = trackingMode == .followHeading
                            ? (viewModel.currentHeading ?? (location.course >= 0 ? location.course : 0))
                            : 0
                        animateCamera(duration: 0.6) {
                            viewModel.followUser(at: location, heading: heading)
                        }
                    }
                }
            )
            .presentationDetents(sheetDetents, selection: $searchDetent)
            .presentationDragIndicator(.visible)
            // Must name a detent that's actually in `sheetDetents` — otherwise the whole map
            // behind the sheet stops receiving touches.
            .presentationBackgroundInteraction(
                .enabled(upThrough: directionsViewModel.isActive ? .medium : .home)
            )
            .presentationSizing(.page)
            .presentationCornerRadius(28)
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $isSearchingAlongRoute) {
            SearchAlongRouteSheet(remainingCoordinates: navigationViewModel.remainingCoordinates) { coordinate in
                navigationViewModel.addStop(coordinate)
            }
        }
        .onChange(of: searchViewModel.selectedResult) { _, newValue in
            guard let newValue else { return }
            viewModel.centerCamera(on: newValue.coordinate)
        }
        .onChange(of: viewModel.currentLocation) { _, newValue in
            if let newValue { directionsViewModel.updateOrigin(newValue) }
        }
        // Tapping a built-in map POI (a restaurant, shop, landmark) opens the same rich place
        // card you'd get by searching for it.
        .onChange(of: selectedMapFeature) { _, feature in
            guard let feature else { return }
            searchViewModel.selectMapFeature(feature)
            selectedMapFeature = nil
        }
    }

    /// Apple Maps only ever offers three heights, so one pull from the resting card goes straight
    /// to full screen. Directions swap the middle stop for a taller one that fits the whole card
    /// (and a short one so the header/close button stays reachable when it's dragged down).
    private var sheetDetents: Set<PresentationDetent> {
        if directionsViewModel.isActive {
            return [.height(190), .medium, .large]
        }
        return [.height(collapsedHeight), .home, .large]
    }

    /// Recomputes the active navigation route from wherever the driver currently is to the
    /// destination, through whatever stops are on file — used both for drifting off the
    /// original path and for a stop added mid-trip via search-along-route, since both are "the
    /// route changed, get a new one" the same way.
    private func recomputeActiveRoute() {
        guard !isRerouting else { return }
        isRerouting = true
        Task {
            defer { isRerouting = false }
            guard let location = viewModel.currentLocation else { return }
            guard let options = try? await GoogleRoutesService().computeRoutes(
                from: location.coordinate,
                to: navigationViewModel.destinationCoordinate,
                mode: .drive,
                avoidTolls: directionsViewModel.avoidTolls,
                avoidHighways: directionsViewModel.avoidHighways,
                avoidFerries: directionsViewModel.avoidFerries,
                intermediates: navigationViewModel.intermediateStops
            ), let newRoute = options.first else { return }
            navigationViewModel.reroute(to: newRoute)
            // A reroute changes the ETA/instruction enough that it's worth refreshing right
            // away rather than waiting out the normal GPS-driven throttle window.
            let arrival = Date().addingTimeInterval(newRoute.travelTime)
            let minutes = max(1, Int((newRoute.travelTime / 60).rounded()))
            liveActivity.update(
                instruction: navigationViewModel.currentStep?.instruction ?? navigationViewModel.destinationName,
                remainingMinutes: minutes,
                remainingDistanceText: navigationViewModel.formattedRemainingDistance,
                arrivalDate: arrival
            )
            NavigationWidgetDataStore.publish(
                .init(destinationName: navigationViewModel.destinationName, arrivalDate: arrival, remainingMinutes: minutes)
            )
            lastLiveActivityUpdate = Date()
        }
    }

    /// Routes every programmatic camera move through one throttle so the GPS-fix path and the
    /// compass-heading path never both animate the same camera at once and fight each other.
    private func animateCamera(duration: Double, linear: Bool = false, _ body: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastCameraAnimation) > duration * 0.6 else { return }
        lastCameraAnimation = now
        withAnimation(linear ? .linear(duration: duration) : .smooth(duration: duration)) {
            body()
        }
    }

    private func handleLocationButtonTap() {
        // Tapping re-center is how the user hands control back to automatic follow.
        isCameraUserControlled = false
        lastCameraAnimation = .distantPast
        switch trackingMode {
        case .off:
            trackingMode = .follow
            animateCamera(duration: 0.5) {
                viewModel.recenterOnUser()
            }
        case .follow:
            trackingMode = .followHeading
            if let location = viewModel.currentLocation {
                let heading = viewModel.currentHeading ?? 0
                animateCamera(duration: 0.5) {
                    viewModel.followUser(at: location, heading: heading)
                }
            }
        case .followHeading:
            trackingMode = .follow
            animateCamera(duration: 0.5) {
                viewModel.recenterOnUser()
            }
        }
    }

    private var mapControlsOverlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                if isCloseEnoughForStreetControls {
                    GlassEffectContainer(spacing: 4) {
                        VStack(spacing: 4) {
                            ClearMapButton {
                                withAnimation(.snappy(duration: 0.4)) {
                                    viewModel.toggle3D(from: currentCamera)
                                }
                            } label: {
                                Text(is3D ? "2D" : "3D")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            LookAroundButton(coordinate: mapCenter ?? viewModel.currentLocation?.coordinate)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer()

                FusedRightControls(
                    mapStyle: $mapStyle,
                    trackingMode: trackingMode,
                    onRecenter: handleLocationButtonTap
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, sheetHeight + 20)
            .animation(.smooth(duration: 0.3), value: sheetHeight)
            .animation(.snappy(duration: 0.35), value: isCloseEnoughForStreetControls)
        }
    }

    private var is3D: Bool {
        (currentCamera?.pitch ?? 0) > 1
    }

    /// Apple Maps only shows 3D/Look Around once you're zoomed to roughly street/neighborhood level.
    private var isCloseEnoughForStreetControls: Bool {
        guard let distance = currentCamera?.distance else { return false }
        return distance < 4000
    }

    @ViewBuilder
    private var navigationOverlay: some View {
        ZStack(alignment: .top) {
            // Floating controls sit above the card and ride up/down with it as it expands.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Button(action: handleLocationButtonTap) {
                        Image(systemName: trackingMode == .followHeading ? "location.north.line.fill" : "location.north.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(trackingMode == .followHeading ? Color.accentColor : Color.primary)
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.clear.interactive(), in: Circle())

                    Spacer()

                    navigationSideButtons
                }
                .padding(.horizontal, 16)
                .padding(.bottom, navBarHeight + 14)
                .animation(.smooth(duration: 0.35), value: navBarHeight)
            }

            VStack {
                NavigationBanner(
                    currentInstruction: navigationViewModel.currentStep?.instruction ?? "Head to \(navigationViewModel.destinationName)",
                    nextInstruction: navigationViewModel.nextStep?.instruction
                )
                .padding(.top, 4)

                if let limit = speedLimitService.display {
                    HStack {
                        SpeedLimitSign(speedLimit: limit.value, unitLabel: limit.unit)
                            .padding(.leading, 16)
                            .padding(.top, 6)
                            .transition(.scale.combined(with: .opacity))
                        Spacer()
                    }
                }
                Spacer()
            }
            .animation(.smooth(duration: 0.3), value: speedLimitService.display?.value)

            VStack {
                Spacer()
                NavigationBottomBar(
                    arrival: navigationViewModel.formattedArrival,
                    minutes: navigationViewModel.formattedRemainingMinutes,
                    distance: navigationViewModel.formattedRemainingDistance,
                    destinationName: navigationViewModel.destinationName,
                    isMuted: voiceGuidance.isMuted,
                    onEndRoute: {
                        navigationViewModel.end()
                        speedLimitService.reset()
                        liveActivity.end()
                        NavigationWidgetDataStore.clear()
                    },
                    onToggleMute: { voiceGuidance.isMuted.toggle() },
                    onHeightChange: { navBarHeight = $0 }
                )
            }
        }
    }

    /// Route-overview / mute / report stack on the right, matching Apple Maps' nav controls.
    private var navigationSideButtons: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                Button {
                    if let route = navigationViewModel.route {
                        animateCamera(duration: 0.6) {
                            viewModel.fitCamera(toRoute: route.boundingMapRect)
                        }
                    }
                } label: {
                    navSideIcon("point.topleft.down.to.point.bottomright.curvepath")
                }
                .buttonStyle(.plain)

                Divider().frame(width: 30).overlay(Color.primary.opacity(0.15))

                Button {
                    isSearchingAlongRoute = true
                } label: {
                    navSideIcon("magnifyingglass")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("searchAlongRouteButton")

                Divider().frame(width: 30).overlay(Color.primary.opacity(0.15))

                Button {
                    voiceGuidance.isMuted.toggle()
                } label: {
                    navSideIcon(voiceGuidance.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("muteButton")
            }
            .glassEffect(.clear.interactive(), in: Capsule())
        }
    }

    private func navSideIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var weatherWidgetOverlay: some View {
        if let temperature = weatherService.temperature, let symbolName = weatherService.symbolName {
            VStack {
                HStack {
                    WeatherWidgetView(temperature: temperature, symbolName: symbolName, airQualityIndex: weatherService.airQualityIndex)
                        .padding(.leading, 12)
                        .padding(.top, 8)
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

/// The time label drawn on each route line; tapping it selects that route.
private struct RouteTimeBubble: View {
    let text: String
    var label: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(text)
                    .font(.caption.weight(.semibold))
                if isSelected, let label {
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .opacity(0.9)
                }
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.ultraThickMaterial),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(isSelected ? 0.6 : 0.2), lineWidth: 1))
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
    }
}

/// A clear (translucent) Liquid Glass circular map control, matching Apple Maps' 3D/location buttons.
private struct ClearMapButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: Circle())
    }
}

/// The recenter-location and map-style buttons fused into a single Liquid Glass pill,
/// matching Apple Maps rather than rendering as two separate circular buttons.
private struct FusedRightControls: View {
    @Binding var mapStyle: MapStyle
    let trackingMode: UserTrackingMode
    let onRecenter: () -> Void

    private var locationSymbol: String {
        switch trackingMode {
        case .off: "location"
        case .follow: "location.fill"
        case .followHeading: "location.north.line.fill"
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                Button(action: onRecenter) {
                    Image(systemName: locationSymbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(trackingMode == .off ? Color.primary : Color.accentColor)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(width: 30)
                    .overlay(Color.primary.opacity(0.15))

                Menu {
                    Button("Standard") { mapStyle = .standard }
                    Button("Satellite") { mapStyle = .imagery }
                    Button("Hybrid") { mapStyle = .hybrid }
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .glassEffect(.clear.interactive(), in: Capsule())
        }
    }
}

/// Apple Maps–style Look Around (binoculars). Fetches a street-level scene for the
/// current map center and presents it; the button is disabled where no scene exists.
private struct LookAroundButton: View {
    let coordinate: CLLocationCoordinate2D?

    @State private var scene: MKLookAroundScene?
    @State private var isLoading = false
    @State private var isPresented = false

    var body: some View {
        Button {
            Task { await presentIfAvailable() }
        } label: {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "binoculars.fill")
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: Circle())
        .accessibilityIdentifier("lookAroundButton")
        .task(id: coordinateKey) {
            await refreshScene()
        }
        .disabled(scene == nil && !isLoading)
        .opacity(scene == nil && !isLoading ? 0.5 : 1)
        .fullScreenCover(isPresented: $isPresented) {
            if let scene {
                LookAroundScenePresenter(scene: scene) { isPresented = false }
            }
        }
    }

    private var coordinateKey: String {
        guard let coordinate else { return "none" }
        return "\(coordinate.latitude.rounded(toPlaces: 3)),\(coordinate.longitude.rounded(toPlaces: 3))"
    }

    private func refreshScene() async {
        guard let coordinate else { scene = nil; return }
        let request = MKLookAroundSceneRequest(coordinate: coordinate)
        scene = try? await request.scene
    }

    private func presentIfAvailable() async {
        if scene == nil {
            isLoading = true
            await refreshScene()
            isLoading = false
        }
        if scene != nil { isPresented = true }
    }
}

private struct LookAroundScenePresenter: View {
    let scene: MKLookAroundScene
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LookAroundPreview(initialScene: scene)
                .ignoresSafeArea()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .padding()
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

private struct LocationPermissionDeniedView: View {
    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 12) {
                Image(systemName: "location.slash.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Location Access Needed")
                    .font(.headline)
                Text("Waypoint uses your location to center the map and show places near you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.glassProminent)
            }
            .padding(24)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
    }
}

#Preview {
    MapScreen()
}
