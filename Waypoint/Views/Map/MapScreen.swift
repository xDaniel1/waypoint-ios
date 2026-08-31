import MapKit
import OSLog
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
    @State private var lastWeatherAttempt: Date = .distantPast
    @State private var searchDetent: PresentationDetent = .home
    @State private var collapsedHeight: CGFloat = 90
    /// Measured live from DirectionsCard's actual content so the sheet hugs it exactly instead
    /// of leaving dead space the way a fixed `.medium` fraction did. 420 is just a first-frame
    /// placeholder before any measurement has come back.
    @State private var directionsCardHeight: CGFloat = 180
    /// The search sheet's own content report (via `GeometryReader` inside `SearchSheet`) ran
    /// well taller than where its card actually starts once `.fixedSize` settles it — chasing
    /// that number left the floating map buttons hovering a card's-height above the card instead
    /// of just clear of it. The sheet only ever rests at one of a few fixed fractions of the
    /// screen anyway, so this multiplies that fraction directly instead of trusting the
    /// measured value.
    @State private var screenHeight: CGFloat = 956
    /// Explore on launch, the way Apple opens. Traffic colouring now belongs to Driving alone —
    /// see `MapMode`.
    @State private var mapMode: MapMode = .explore
    @State private var isShowingMapModes = false
    @State private var mapCenter: CLLocationCoordinate2D?
    /// One-shot: the discover shelves are warmed on the first camera settle, not on every pan.
    @State private var hasPrefetchedDiscover = false
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var currentCamera: MapCamera?
    @State private var trackingMode: UserTrackingMode = .off
    /// Shared between the GPS-fix and compass-heading update paths so they never both animate
    /// the camera within the same window — that fight was the source of the stutter/snapping.
    @State private var lastCameraAnimation: Date = .distantPast
    /// Compass rotation gets its own clock — see `animateHeading`.
    @State private var lastHeadingAnimation: Date = .distantPast
    /// Ground metres covered by one screen point at the current zoom, refreshed whenever the
    /// camera settles. Only used to size the blue dot's accuracy halo.
    @State private var metresPerPoint: Double = 1
    @State private var navBarHeight: CGFloat = 120
    /// Measured from the transit card, which replaces the driving bottom bar during a transit
    /// trip — without this the map controls were spaced off a bar that wasn't on screen and ended
    /// up sitting directly on the card.
    @State private var transitCardHeight: CGFloat = 150
    @State private var voiceGuidance = VoiceGuidanceService()
    @State private var speedLimitService = SpeedLimitService()
    @State private var navigationNotifications = NavigationNotificationService()
    @State private var isRerouting = false
    @State private var isSearchingAlongRoute = false
    @State private var isAddingNavStop = false
    /// Owned here rather than inside SearchSheet: the sheet's content gets rebuilt when the
    /// detent changes, which reset SearchSheet's local @State and immediately flipped the stop
    /// picker back off. `detent` already lives here for the same reason.
    @State private var isAddingDirectionsStop = false
    @State private var stepsRoute: RouteOption?
    @State private var isReportingIncident = false
    @State private var showingTransitDetails = false
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

    /// Runs whatever Siri or a Shortcut asked for, once the map is actually on screen.
    /// Resolved through MapKit rather than trusting the spoken string as a coordinate.
    private func handlePendingIntent() async {
        guard let request = PendingIntent.shared.request else { return }
        PendingIntent.shared.request = nil

        let query: String
        let startsDirections: Bool
        switch request {
        case .search(let text):
            query = text
            startsDirections = false
        case .directions(let text):
            query = text
            startsDirections = true
        }

        let searchRequest = MKLocalSearch.Request()
        searchRequest.naturalLanguageQuery = query
        if let coordinate = viewModel.currentLocation?.coordinate {
            searchRequest.region = MKCoordinateRegion(
                center: coordinate, latitudinalMeters: 20000, longitudinalMeters: 20000
            )
        }
        guard let item = try? await MKLocalSearch(request: searchRequest).start().mapItems.first else {
            Logger.navigation.error("Intent query had no match: \(query)")
            return
        }

        searchViewModel.selectResult(SearchResult(mapItem: item))
        if startsDirections {
            directionsViewModel.start(destination: item, from: viewModel.currentLocation)
        }
    }

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
                                headingAccuracy: viewModel.currentHeadingAccuracy ?? 30,
                                accuracyRadiusPoints: accuracyRadiusInPoints
                            )
                        }
                    }
                    .annotationTitles(.hidden)
                } else {
                    UserAnnotation()
                }
                if shouldDrawTransitLines {
                    // `MapPolyline(_:)` over a prebuilt MKPolyline, not `MapPolyline(coordinates:)`
                    // — the map's content closure re-runs on every location fix, and the
                    // coordinates form re-copied all 29 lines' points each time.
                    ForEach(MTASubwayLines.all) { line in
                        MapPolyline(line.polyline)
                            .stroke(line.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    }
                }

                if let result = searchViewModel.selectedResult {
                    Marker(result.title, coordinate: result.coordinate)
                        .tint(.indigo)
                }
                // Browsing a category drops a pin for every hit, the way Apple fills the map
                // when you tap "Restaurants" — the list alone told you what was nearby without
                // showing you where any of it actually was.
                if searchViewModel.selectedResult == nil {
                    ForEach(searchViewModel.categoryResults) { place in
                        if let coordinate = place.coordinate {
                            Marker(
                                place.displayName?.text ?? "Place",
                                systemImage: searchViewModel.categorySymbol,
                                coordinate: coordinate
                            )
                            .tint(.orange)
                            .annotationTitles(.hidden)
                        }
                    }
                }
                ForEach(directionsViewModel.stops) { stop in
                    Marker(stop.title, coordinate: stop.coordinate)
                        .tint(.orange)
                }
                ForEach(navigationViewModel.reportedIncidents) { incident in
                    Annotation(incident.kind.rawValue, coordinate: incident.coordinate) {
                        Image(systemName: incident.kind.symbol)
                            .scaledFont(size: 14, weight: .bold, relativeTo: .footnote)
                            .foregroundStyle(incident.kind.iconColor)
                            .padding(6)
                            .background(incident.kind.tint, in: Circle())
                    }
                    .annotationTitles(.hidden)
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
                    if selected.transitSegments.isEmpty {
                        // Transit rides draw in the operator's own line colour (the J's gold, the
                        // G's green) rather than generic blue, matching how Apple colours the route.
                        MapPolyline(selected.polyline)
                            .stroke(selected.routeTint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    } else {
                        // A trip with a transfer isn't one colour. Each leg draws in the colour of
                        // the service you're on for it — the J brown up to the transfer, the A blue
                        // after — with the walks between them dotted grey, the way Apple does it.
                        ForEach(selected.transitSegments) { segment in
                            MapPolyline(coordinates: segment.coordinates)
                                .stroke(segment.color, style: segment.strokeStyle)
                        }
                    }
                    // Colored on top of the base line wherever Google's live traffic data says
                    // this stretch is actually slower than free-flow — not just the whole-route
                    // "has traffic" badge.
                    ForEach(selected.congestionSegments) { segment in
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(segment.severity.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(Array(directionsViewModel.routeOptions.enumerated()), id: \.element.id) { index, option in
                    routeTimeBubbleAnnotation(index: index, option: option)
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
                    // A transit trip in progress keeps its per-line colours — the leg you're on
                    // and the ones still ahead at full strength, the ones already ridden dimmed,
                    // so a glance tells you both where you are and which train you're on next.
                    ForEach(navigationViewModel.drawableSegments) { piece in
                        MapPolyline(coordinates: piece.coordinates)
                            .stroke(
                                piece.color.opacity(piece.isTraveled ? 0.35 : 1),
                                style: piece.strokeStyle
                            )
                    }
                    if let route = navigationViewModel.route {
                        ForEach(route.congestionSegments) { segment in
                            MapPolyline(coordinates: segment.coordinates)
                                .stroke(segment.severity.color, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
            .mapStyle(activeMapStyle)
            .mapControls { MapScaleView(scope: mapScope) }
            // Deliberately no bottom `safeAreaPadding` here. MapKit pins its own mandatory
            // attribution ("Maps · Legal") to the bottom of the *map's safe area*, so insetting
            // the bottom by the sheet's height lifted that text off the bottom edge and parked it
            // in the middle of the map. Leaving the safe area alone keeps it tucked in the
            // bottom-left corner behind the sheet, where it was before and where it isn't in the way.
            .onMapCameraChange(frequency: .onEnd) { context in
                searchViewModel.updateSearchRegion(context.region)
                mapCenter = context.region.center
                // 111_320m is a degree of latitude; longitude varies with latitude but the halo
                // is a circle either way, so the vertical scale is the one that matters.
                let visibleMetres = context.region.span.latitudeDelta * 111_320
                metresPerPoint = max(visibleMetres / max(screenHeight, 1), 0.0001)
                withAnimation(.smooth(duration: 0.35)) {
                    currentCamera = context.camera
                }
                // Warm the search page's shelves once the map knows where we are, instead of
                // waiting for the user to tap the field and then watch it load. Bounded on
                // purpose: `loadIfNeeded` no-ops within 500m of the last load and every call
                // underneath is disk-cached for 2h+, so this is a couple of requests per session,
                // and they're the same ones opening search would have spent anyway.
                if !hasPrefetchedDiscover {
                    hasPrefetchedDiscover = true
                    searchViewModel.loadDiscover()
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

            if !networkMonitor.isConnected {
                VStack {
                    OfflineBanner()
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
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
        .animation(.smooth(duration: 0.3), value: networkMonitor.isConnected)
        .mapScope(mapScope)
        // `.task` covers a cold launch from Siri; the `onChange` covers an intent firing while
        // the app is already open, which `.task` alone would miss.
        .task { await handlePendingIntent() }
        .onChange(of: PendingIntent.shared.request) { _, newValue in
            guard newValue != nil else { return }
            Task { await handlePendingIntent() }
        }
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
                    // Linear, not `.smooth`: fixes now arrive faster than the animation lasts,
                    // so an eased curve restarted every fix read as a pulse — accelerate, coast,
                    // decelerate, repeat. Linear segments chain into one continuous glide.
                    animateCamera(duration: 0.9, linear: true) {
                        viewModel.followUser(at: location, heading: heading)
                    }
                } else if trackingMode == .follow, !isCameraUserControlled {
                    // Recenter without rotating — the map stays north-up, only the dot moves.
                    animateCamera(duration: 0.6, linear: true) {
                        viewModel.recenterKeepingZoom(on: location, camera: currentCamera)
                    }
                }
                // Marking this fetched *before* awaiting meant a single failure — no network yet
                // on launch, WeatherKit not warmed up — permanently suppressed the widget for the
                // rest of the session. Retry until it actually succeeds.
                guard !weatherService.hasCurrentConditions else { return }
                guard Date().timeIntervalSince(lastWeatherAttempt) > 20 else { return }
                lastWeatherAttempt = Date()
                Task { await weatherService.refresh(for: location) }
            }
            directionsViewModel.onRoutesChanged = { _, selected in
                if let selected {
                    viewModel.fitCamera(toRoute: selected.boundingMapRect)
                }
            }
            navigationViewModel.onAnnouncement = { text in
                voiceGuidance.speak(text)
                // A tap alongside the voice cue so a turn still registers over road noise or
                // when muted — Apple Maps does the same on the Watch and CarPlay.
                Haptics.commit()
                // No-op unless the app is actually backgrounded — see
                // NavigationNotificationService for why this isn't real push.
                navigationNotifications.postNextTurn(text)
            }
            // The view model can tell us we've drifted off the path, or that a stop was added
            // mid-trip via search-along-route — either way it doesn't fetch routes itself,
            // that's recomputeActiveRoute()'s job.
            navigationViewModel.onOffRoute = { recomputeActiveRoute() }
            navigationViewModel.onStopAdded = { recomputeActiveRoute() }
            navigationViewModel.onIncidentReported = { recomputeActiveRoute() }
            await viewModel.start()
        }
        // Compass-driven camera rotation ONLY applies once the user explicitly opts in via the
        // location button's heading mode (2nd tap) — never automatically, not even while
        // navigating. Otherwise the base map stays fixed and only the blue dot's heading cone
        // moves, matching how iOS itself behaves.
        .onChange(of: viewModel.currentHeading) { _, newHeading in
            guard let newHeading, let location = viewModel.currentLocation else { return }
            guard trackingMode == .followHeading else { return }
            // Rotation runs on its own throttle. It shares nothing with the GPS-follow path any
            // more: the compass fires far more often than fixes arrive, and on one shared clock
            // it was eating the budget and leaving the map trailing behind a moving rider.
            animateHeading(duration: 0.25, linear: true) {
                if navigationViewModel.isActive {
                    viewModel.followUser(at: location, heading: newHeading)
                } else {
                    viewModel.orientToHeading(at: location, heading: newHeading, camera: currentCamera)
                }
            }
        }
        .sheet(isPresented: .constant(!navigationViewModel.isActive)) {
            SearchSheet(
                viewModel: searchViewModel,
                directionsViewModel: directionsViewModel,
                currentLocation: viewModel.currentLocation,
                detent: $searchDetent,
                collapsedHeight: $collapsedHeight,
                directionsHeight: $directionsCardHeight,
                isAddingStop: $isAddingDirectionsStop,
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
                    // Kick off the first lookup here rather than waiting on a location update —
                    // starting from a standstill can otherwise leave the sign blank until the
                    // first 80m of movement.
                    if let location = viewModel.currentLocation {
                        Task { await speedLimitService.refreshIfNeeded(at: location) }
                    }
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
                    // Contextual, not upfront: this is the moment background tracking actually
                    // becomes useful, which is exactly when Apple expects an Always-location ask.
                    viewModel.beginBackgroundTracking(driving: directionsViewModel.mode == .automobile)
                    Task { await navigationNotifications.requestAuthorization() }
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
                },
                onShowSteps: { route in stepsRoute = route }
            )
            .presentationDetents(sheetDetents, selection: $searchDetent)
            .presentationDragIndicator(.visible)
            // Must name a detent that's actually in `sheetDetents` — otherwise the whole map
            // behind the sheet stops receiving touches.
            .presentationBackgroundInteraction(
                .enabled(upThrough: directionsViewModel.isActive ? .directionsRest : .home)
            )
            // No `.presentationSizing(.page)` here: that's an iPad/Mac page-sizing API, and on
            // iPhone it overrode the detents entirely — the home card rendered at nearly full
            // screen height regardless of `.fraction(0.45)` and ran off the bottom edge, clipping
            // the last row. Plain detents let the sheet size itself to the screen properly.
            .interactiveDismissDisabled(true)
            // Chained onto SearchSheet itself, not sibling .sheet() modifiers on MapScreen's own
            // root: the outer SearchSheet sheet is presented essentially the whole time the user
            // isn't actively navigating, so a sibling .sheet() here would be a second *independent*
            // sheet trying to present itself while another already is — the exact "sheet from a
            // sheet" pattern that silently never shows on this SwiftUI version. Presenting instead
            // from the already-open sheet's own content chains it onto the same, single active
            // presentation, which iOS handles correctly.
            // Chained here for the same reason as the steps sheet below: the search sheet is
            // already presented, so a sibling `.sheet` on MapScreen's root would never show.
            .sheet(isPresented: $isShowingMapModes) {
                MapModesCard(mode: $mapMode, onClose: { isShowingMapModes = false })
                .presentationDetents([.height(190)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
            }
            .sheet(item: $stepsRoute) { route in
                // Transit has no `RouteStep` list by nature, so the generic steps sheet could
                // only ever say "turn-by-turn isn't available". The itinerary is the directions
                // for this mode.
                if route.transitSteps.isEmpty {
                    RouteStepsSheet(destination: directionsViewModel.destinationTitle, route: route)
                } else {
                    TransitItinerarySheet(
                        route: route,
                        destinationName: directionsViewModel.destinationTitle,
                        onClose: { stepsRoute = nil }
                    )
                }
            }
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
        .onChange(of: directionsViewModel.isActive) { oldValue, active in
            if active {
                searchDetent = .directionsRest
            } else if oldValue == true {
                searchDetent = .home
                if let currentCamera, currentCamera.pitch > 1 {
                    viewModel.resetTo2D(from: currentCamera)
                }
            }
        }
        .onChange(of: navigationViewModel.isActive) { oldValue, active in
            if !active && oldValue == true {
                if let currentCamera, currentCamera.pitch > 1 {
                    viewModel.resetTo2D(from: currentCamera)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { screenHeight = proxy.size.height }
            }
        }
    }

    /// How much room the bottom controls need to clear whatever is docked below them — the
    /// driving bar, or the transit card when a transit trip is running.
    private var bottomControlClearance: CGFloat {
        let isTransit = navigationViewModel.route.map { !$0.transitSteps.isEmpty } ?? false
        return (isTransit ? transitCardHeight : navBarHeight) + 14
    }

    /// Turn-by-turn tilts the map into 3D, and it colours traffic — but only when the trip is
    /// actually a drive. Riding the subway with the roads painted red was noise about a road
    /// you're not on.
    private var activeMapStyle: MapStyle {
        guard navigationViewModel.isActive else { return mapMode.style }
        let isDriving = directionsViewModel.mode == .automobile
        return .standard(elevation: .realistic, pointsOfInterest: .all, showsTraffic: isDriving)
    }

    /// Transit lines are only drawn in transit mode, inside the region they describe, and only
    /// once zoomed in enough for them to mean anything — at state level 29 overlapping polylines
    /// are just noise.
    private var shouldDrawTransitLines: Bool {
        guard mapMode.showsTransitLines, let center = mapCenter else { return false }
        let inRegion = (40.4...41.1).contains(center.latitude)
            && (-74.35...(-73.6)).contains(center.longitude)
        let zoomedIn = (currentCamera?.distance ?? 0) < 45_000
        return inRegion && zoomedIn
    }

    private var sheetDetents: Set<PresentationDetent> {
        if directionsViewModel.isActive {
            // Fixed stops on purpose. This used to include `.height(directionsCardHeight)`, a
            // value that changed every time the card re-measured — so the detent *set* changed
            // identity mid-gesture and SwiftUI rebuilt the sheet's drag behaviour underneath the
            // user's finger. That's what made pulling the card down stick, jump, and land on a
            // height the content didn't fit. A stable set drags smoothly.
            return [.height(190), .directionsRest, .large]
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
            let destinationItem = MKMapItem(placemark: MKPlacemark(coordinate: navigationViewModel.destinationCoordinate))
            let stopItems = navigationViewModel.intermediateStops.map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) }
            guard let options = try? await AppleRoutesService().computeRoutes(
                from: location.coordinate,
                to: destinationItem,
                stops: stopItems,
                transportType: .automobile,
                avoidTolls: directionsViewModel.avoidTolls,
                avoidHighways: directionsViewModel.avoidHighways
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

    /// Throttles the GPS-fix-driven camera moves so two fixes arriving close together don't
    /// stack animations on the same camera.
    private func animateCamera(duration: Double, linear: Bool = false, _ body: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastCameraAnimation) > duration * 0.6 else { return }
        lastCameraAnimation = now
        withAnimation(linear ? .linear(duration: duration) : .smooth(duration: duration)) {
            body()
        }
    }

    /// The same, on a separate clock for compass-driven rotation.
    ///
    /// These used to share `lastCameraAnimation`, and because heading updates arrive far more
    /// often than location fixes, the heading path kept claiming the window and the recenter
    /// that should have followed a fix got dropped — the map visibly trailing behind someone
    /// actually moving. Two clocks means neither can starve the other.
    private func animateHeading(duration: Double, linear: Bool = false, _ body: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastHeadingAnimation) > duration * 0.6 else { return }
        lastHeadingAnimation = now
        withAnimation(linear ? .linear(duration: duration) : .smooth(duration: duration)) {
            body()
        }
    }

    private func handleLocationButtonTap() {
        // Tapping re-center is how the user hands control back to automatic follow.
        isCameraUserControlled = false
        lastCameraAnimation = .distantPast
        lastHeadingAnimation = .distantPast
        switch trackingMode {
        case .off:
            Haptics.select()
            trackingMode = .follow
            animateCamera(duration: 0.5) {
                viewModel.recenterOnUser()
            }
        case .follow:
            Haptics.select()
            trackingMode = .followHeading
            // Apple's second tap spins the map so the way you're facing points up, and changes
            // nothing else. Going through `followUser` here used to also force a 400m tilted
            // navigation camera, so browsing the map and asking to face north-of-you threw you
            // into a 3D street view you never asked for.
            if let location = viewModel.currentLocation {
                let heading = viewModel.currentHeading ?? 0
                animateCamera(duration: 0.5) {
                    viewModel.orientToHeading(at: location, heading: heading, camera: currentCamera)
                }
            }
        case .followHeading:
            Haptics.select()
            trackingMode = .follow
            if let location = viewModel.currentLocation {
                animateCamera(duration: 0.5) {
                    viewModel.straightenToNorth(at: location, camera: currentCamera)
                }
            }
        }
    }

    /// How far up from the bottom the floating map buttons (recenter/layers, compass) sit —
    /// tied directly to the fixed height/fraction the sheet is actually resting at, rather than
    /// a measured content height, which ran the buttons a card's-height too high above the
    /// directions card.
    ///
    /// This has to check every detent in `sheetDetents`, not just the resting one — collapsing
    /// the sheet to its short peek height used to leave the buttons stranded up at the home
    /// detent's fraction because this only ever accounted for `.home`/`.directionsRest`.
    private var mapControlsBottomPadding: CGFloat {
        if searchDetent == .large {
            // The sheet covers nearly the whole screen at `.large`; hug the controls just under
            // the search bar's row instead of a bottom offset that'd sit under the sheet.
            return screenHeight - 140
        }
        if directionsViewModel.isActive {
            if searchDetent == .height(190) { return 190 + 12 }
            return screenHeight * 0.46 + 12
        }
        if searchDetent == .height(collapsedHeight) { return collapsedHeight + 12 }
        return screenHeight * 0.47 + 12
    }

    private var mapControlsOverlay: some View {
        VStack {
            if searchViewModel.showSearchHereButton && !directionsViewModel.isActive {
                searchHereOverlay
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 54)
            }
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
                                    .scaledFont(size: 16, weight: .semibold, relativeTo: .callout)
                            }
                            LookAroundButton(coordinate: mapCenter ?? viewModel.currentLocation?.coordinate)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer()

                VStack(spacing: 8) {
                    if isMapRotated {
                        CompassRoseButton(heading: currentCamera?.heading ?? 0) {
                            withAnimation(.smooth(duration: 0.4)) {
                                viewModel.resetHeading(from: currentCamera)
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                    FusedRightControls(
                        trackingMode: trackingMode,
                        onRecenter: handleLocationButtonTap,
                        onOpenMapModes: {
                            Haptics.tap()
                            isShowingMapModes = true
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, mapControlsBottomPadding)
            .animation(.smooth(duration: 0.3), value: directionsViewModel.isActive)
            .animation(.smooth(duration: 0.3), value: searchDetent)
            .animation(.snappy(duration: 0.35), value: isCloseEnoughForStreetControls)
        }
        .animation(.smooth(duration: 0.3), value: searchViewModel.showSearchHereButton)
        .animation(.smooth(duration: 0.3), value: isMapRotated)
    }

    /// The accuracy halo's radius in screen points, or 0 when there's nothing worth drawing.
    ///
    /// Hidden below 25m because a good open-sky fix doesn't need a caveat and a permanent ring
    /// around the dot would just be noise, and clamped at the top so a really bad fix — the kind
    /// you get on a platform underground — shades the neighbourhood rather than the whole screen.
    private var accuracyRadiusInPoints: Double {
        let accuracy = viewModel.horizontalAccuracy
        guard accuracy >= 25 else { return 0 }
        return min(accuracy / metresPerPoint, 260)
    }

    private var isMapRotated: Bool {
        abs(currentCamera?.heading ?? 0) > 1.5
    }

    private var searchHereOverlay: some View {
        Button {
            if let center = mapCenter {
                searchViewModel.searchInCurrentRegion(center: center)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Text("Search Here")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
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
        ZStack {
            ZStack(alignment: .top) {
                // Floating controls sit above the card and ride up/down with it as it expands.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom) {
                        Button(action: handleLocationButtonTap) {
                            Image(systemName: trackingMode == .followHeading ? "location.north.line.fill" : "location.north.fill")
                                .scaledFont(size: 18, weight: .medium, relativeTo: .body)
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
                    .padding(.bottom, bottomControlClearance)
                    .animation(.smooth(duration: 0.35), value: navBarHeight)
                }

                if let route = navigationViewModel.route, !route.transitSteps.isEmpty {
                    VStack {
                        Spacer()
                        TransitNavigationCardView(
                            route: route,
                            destinationName: navigationViewModel.destinationName,
                            onClose: {
                                navigationViewModel.end()
                                speedLimitService.reset()
                            },
                            onMore: { showingTransitDetails = true }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 24)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newValue in
                            let quantized = (newValue / 8).rounded() * 8
                            guard abs(quantized - transitCardHeight) >= 8 else { return }
                            transitCardHeight = quantized
                        }
                    }
                } else {
                    VStack {
                        // The distance shown is the distance to the *next* maneuver, so the
                        // headline instruction has to be that maneuver's — pairing it with the
                        // current step read as "900 ft" above a blank line, because MapKit
                        // leaves the in-progress step's instruction empty.
                        NavigationBanner(
                            currentInstruction: navigationViewModel.nextStep?.instruction.nilIfEmpty
                                ?? navigationViewModel.currentStep?.instruction.nilIfEmpty
                                ?? "Head to \(navigationViewModel.destinationName)",
                            nextInstruction: navigationViewModel.stepAfterNext?.instruction.nilIfEmpty,
                            distanceToNextStepText: navigationViewModel.formattedDistanceToNextStep,
                            currentManeuverIcon: navigationViewModel.nextStep?.maneuverIcon
                                ?? navigationViewModel.currentStep?.maneuverIcon ?? "arrow.up",
                            nextManeuverIcon: navigationViewModel.stepAfterNext?.maneuverIcon ?? "arrow.up"
                        )

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
                                viewModel.endBackgroundTracking()
                                navigationNotifications.clear()
                            },
                            onAddStop: { isAddingNavStop = true },
                            onShowDetails: { stepsRoute = navigationViewModel.route },
                            onReportIncident: { isReportingIncident = true },
                            onToggleMute: { voiceGuidance.isMuted.toggle() },
                            onHeightChange: { navBarHeight = $0 }
                        )
                    }
                }
            }
            .sheet(isPresented: $showingTransitDetails) {
                if let route = navigationViewModel.route {
                    TransitItinerarySheet(
                        route: route,
                        destinationName: navigationViewModel.destinationName,
                        onClose: { showingTransitDetails = false }
                    )
                }
            }
            .sheet(isPresented: $isAddingNavStop) {
                // Presented from MapScreen's root while navigating, when the search sheet is
                // down — so this one is a genuine top-level sheet and renders fine.
                AddStopSheet(
                    currentRegion: originRegionForAddStop,
                    onCancel: { isAddingNavStop = false }
                ) { item in
                    navigationViewModel.addStop(item.placemark.coordinate)
                    isAddingNavStop = false
                }
            }
            .confirmationDialog("Report an Incident", isPresented: $isReportingIncident, titleVisibility: .visible) {
                ForEach(ReportedIncident.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) {
                        guard let coordinate = viewModel.currentLocation?.coordinate else { return }
                        navigationViewModel.reportIncident(kind, at: coordinate)
                    }
                }
            } message: {
                Text("This marks the spot for this trip and checks for a better route. It isn't shared with other drivers or with Apple/Google traffic data.")
            }
        }
        // Apple Maps forces a dark nav theme at night regardless of the device's own light/dark
        // setting — glare from a bright map at 11pm is the actual reason, not aesthetics. Only
        // overrides while actively driving; browsing the map any other time follows the system.
        .preferredColorScheme(navigationViewModel.isActive && isNightTime ? .dark : nil)
    }

    private var isNightTime: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 20 || hour < 6
    }

    /// Pulled out of the map's ForEach as its own function (with an explicit return type) so the
    /// Swift type-checker doesn't have to fold it into the already-huge `Map` builder expression
    /// above — inlined, this specific combination started timing out the compiler.
    @MapContentBuilder
    private func routeTimeBubbleAnnotation(index: Int, option: RouteOption) -> some MapContent {
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

    private var originRegionForAddStop: MKCoordinateRegion? {
        guard let coordinate = viewModel.currentLocation?.coordinate else { return nil }
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)
    }

    /// CLLocation reports speed in m/s (negative when invalid); converted to whichever unit
    /// the speed limit sign is already using so the two numbers are directly comparable.
    private func currentSpeedValue(matching unit: String) -> Int? {
        guard let speed = viewModel.currentLocation?.speed, speed >= 0 else { return nil }
        let converted = unit == "mph" ? speed * 2.23694 : speed * 3.6
        return Int(converted.rounded())
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
            .scaledFont(size: 17, weight: .medium, relativeTo: .body)
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
    let trackingMode: UserTrackingMode
    let onRecenter: () -> Void
    let onOpenMapModes: () -> Void

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
                        .scaledFont(size: 17, weight: .medium, relativeTo: .body)
                        .foregroundStyle(trackingMode == .off ? Color.primary : Color.accentColor)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(width: 30)
                    .overlay(Color.primary.opacity(0.15))

                // Apple opens a card of live previews here rather than a list of style names,
                // which is the only way to see what "Hybrid" versus "Satellite" actually meant.
                Button(action: onOpenMapModes) {
                    Image(systemName: "map")
                        .scaledFont(size: 18, weight: .medium, relativeTo: .body)
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mapModesButton")
                .accessibilityLabel("Map modes")
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
                        .scaledFont(size: 17, weight: .medium, relativeTo: .body)
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

/// An Apple Maps-style compass button that appears whenever the map is rotated away from North.
private struct CompassRoseButton: View {
    let heading: Double
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            Image(systemName: "location.north.circle.fill")
                .scaledFont(size: 24, weight: .medium, relativeTo: .title2)
                .foregroundStyle(.red, .primary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .rotationEffect(.degrees(-heading))
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: Circle())
        .accessibilityLabel("Reset map to North")
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
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
    }
}

private struct TransitNavigationCardView: View {
    let route: RouteOption
    let destinationName: String
    let onClose: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "figure.walk")
                .scaledFont(size: 32, weight: .semibold, relativeTo: .title)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let firstStep = route.transitSteps.first {
                        Text("Walk to \(firstStep.departureStop) stop")
                            .scaledFont(size: 20, weight: .bold, relativeTo: .title3)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    } else {
                        Text("Walk to \(destinationName)")
                            .scaledFont(size: 20, weight: .bold, relativeTo: .title3)
                            .foregroundStyle(.primary)
                    }

                    Spacer(minLength: 0)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .bold, relativeTo: .footnote)
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                // Was a hardcoded "0.3 miles, about 7 min" — this is the real first walk leg
                // from the transit response, and it's omitted when there isn't one.
                if let walkMinutes = route.firstWalkMinutes {
                    Text("About \(walkMinutes) min walk")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if let firstStep = route.transitSteps.first {
                        LineBadge(step: firstStep)

                        if let departure = route.departureText {
                            Text(departure)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Previously a hardcoded "Now 11:40 PM" next to a live-data wifi glyph,
                        // which implied realtime tracking we don't have.
                        if let minutes = route.minutesUntilDeparture {
                            Text(minutes <= 0 ? "Departing now" : "in \(minutes) min")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer(minLength: 0)

                    Button(action: onMore) {
                        Text("More")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        // Tapping anywhere on the card opens the full itinerary, the way Apple's does; the
        // "More" link stays so the affordance is still visible.
        .contentShape(RoundedRectangle(cornerRadius: 26))
        .onTapGesture { onMore() }
        // Pulling up on the card opens it too, which is how riders instinctively reach for more
        // detail on a docked card.
        .highPriorityGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    if value.translation.height < -18 { onMore() }
                }
        )
    }
}

#Preview {
    MapScreen()
}
