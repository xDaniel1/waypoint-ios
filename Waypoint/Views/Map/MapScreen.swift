import MapKit
import SwiftUI

struct MapScreen: View {
    @State private var viewModel = MapViewModel()
    @State private var searchViewModel = SearchViewModel()
    @State private var directionsViewModel = DirectionsViewModel()
    @State private var navigationViewModel = NavigationViewModel()
    @State private var weatherService = WeatherService()
    @State private var hasFetchedWeather = false
    @State private var searchDetent: PresentationDetent = .height(90)
    @State private var collapsedHeight: CGFloat = 90
    @State private var sheetHeight: CGFloat = 90
    @State private var mapStyle: MapStyle = .standard
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var currentCamera: MapCamera?
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            Map(position: $viewModel.cameraPosition, scope: mapScope) {
                UserAnnotation()
                if let result = searchViewModel.selectedResult {
                    Marker(result.title, coordinate: result.coordinate)
                        .tint(.indigo)
                }
                // Draw alternates first (under), selected route last (on top).
                ForEach(directionsViewModel.routeOptions) { option in
                    if option.id != directionsViewModel.selectedRoute?.id {
                        MapPolyline(option.polyline)
                            .stroke(Color.gray.opacity(0.55),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
                if let selected = directionsViewModel.selectedRoute {
                    MapPolyline(selected.polyline)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
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
                    // Keep the camera glued to the user in 3D follow-mode, animating smoothly
                    // between fixes instead of jump-cutting like Apple Maps' continuous pursuit-cam.
                    let heading = viewModel.currentHeading ?? (location.course >= 0 ? location.course : 0)
                    withAnimation(.smooth(duration: 1.0)) {
                        viewModel.followUser(at: location, heading: heading)
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
            await viewModel.start()
        }
        // Compass-driven camera rotation: fires far more often than GPS fixes, so the map
        // turns with the phone in near real time, the way Apple Maps' puck does.
        .onChange(of: viewModel.currentHeading) { _, newHeading in
            guard navigationViewModel.isActive, let newHeading, let location = viewModel.currentLocation else { return }
            withAnimation(.linear(duration: 0.25)) {
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
                    navigationViewModel.start(route: route, destinationName: name)
                    directionsViewModel.stop()
                    // Zoom straight into the user's pin the moment GO is tapped, instead of
                    // waiting for the next GPS fix to snap the camera into follow-mode.
                    if let location = viewModel.currentLocation {
                        let heading = viewModel.currentHeading ?? (location.course >= 0 ? location.course : 0)
                        withAnimation(.smooth(duration: 0.6)) {
                            viewModel.followUser(at: location, heading: heading)
                        }
                    }
                }
            )
            .presentationDetents([.height(collapsedHeight), .height(380), .medium, .large], selection: $searchDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationSizing(.page)
            .presentationCornerRadius(28)
            .interactiveDismissDisabled(true)
        }
        .onChange(of: searchViewModel.selectedResult) { _, newValue in
            guard let newValue else { return }
            viewModel.centerCamera(on: newValue.coordinate)
        }
        .onChange(of: viewModel.currentLocation) { _, newValue in
            if let newValue { directionsViewModel.updateOrigin(newValue) }
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
                    onRecenter: {
                        withAnimation(.snappy(duration: 0.4)) {
                            viewModel.recenterOnUser()
                        }
                    }
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
        VStack {
            NavigationBanner(
                currentInstruction: navigationViewModel.currentStep?.instruction ?? "Head to \(navigationViewModel.destinationName)",
                nextInstruction: navigationViewModel.nextStep?.instruction
            )
            .padding(.top, 4)
            Spacer()
            HStack {
                Button {
                    if let location = viewModel.currentLocation {
                        let heading = viewModel.currentHeading ?? (location.course >= 0 ? location.course : 0)
                        withAnimation(.snappy(duration: 0.4)) {
                            viewModel.followUser(at: location, heading: heading)
                        }
                    }
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.interactive(), in: Circle())
                .padding(.leading, 14)
                Spacer()
            }
            .padding(.bottom, 10)
            NavigationBottomBar(
                arrival: navigationViewModel.formattedArrival,
                minutes: navigationViewModel.formattedRemainingMinutes,
                distance: navigationViewModel.formattedRemainingDistance,
                destinationName: navigationViewModel.destinationName,
                onEndRoute: {
                    navigationViewModel.end()
                }
            )
        }
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
                .foregroundStyle(.white)
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
    let onRecenter: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                Button(action: onRecenter) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(width: 30)
                    .overlay(Color.white.opacity(0.25))

                Menu {
                    Button("Standard") { mapStyle = .standard }
                    Button("Satellite") { mapStyle = .imagery }
                    Button("Hybrid") { mapStyle = .hybrid }
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
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
            .foregroundStyle(.white)
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
