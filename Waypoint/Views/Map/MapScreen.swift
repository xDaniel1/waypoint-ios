import MapKit
import SwiftUI

struct MapScreen: View {
    @State private var viewModel = MapViewModel()
    @State private var searchViewModel = SearchViewModel()
    @State private var directionsViewModel = DirectionsViewModel()
    @State private var weatherService = WeatherService()
    @State private var hasFetchedWeather = false
    @State private var searchDetent: PresentationDetent = .height(120)
    @State private var mapStyle: MapStyle = .standard
    @Namespace private var mapScope

    var body: some View {
        ZStack {
            Map(position: $viewModel.cameraPosition, scope: mapScope) {
                UserAnnotation()
                if let result = searchViewModel.selectedResult {
                    Marker(result.title, coordinate: result.coordinate)
                        .tint(.indigo)
                }
                if let route = directionsViewModel.route {
                    MapPolyline(route.polyline)
                        .stroke(.blue, lineWidth: 5)
                }
            }
            .mapStyle(mapStyle)
            .onMapCameraChange(frequency: .onEnd) { context in
                searchViewModel.updateSearchRegion(context.region)
            }
            .ignoresSafeArea(edges: .top)

            if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
                LocationPermissionDeniedView()
            }

            mapControlsOverlay
            weatherWidgetOverlay
        }
        .mapScope(mapScope)
        .task {
            viewModel.onLocationUpdate = { location in
                guard !hasFetchedWeather else { return }
                hasFetchedWeather = true
                Task { await weatherService.refresh(for: location) }
            }
            directionsViewModel.onRouteCalculated = { route in
                viewModel.fitCamera(toRoute: route.polyline.boundingMapRect)
            }
            await viewModel.start()
        }
        .sheet(isPresented: .constant(true)) {
            SearchSheet(
                viewModel: searchViewModel,
                directionsViewModel: directionsViewModel,
                currentLocation: viewModel.currentLocation,
                detent: $searchDetent
            )
            .presentationDetents([.height(120), .medium, .large], selection: $searchDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .interactiveDismissDisabled(true)
        }
        .onChange(of: searchViewModel.selectedResult) { _, newValue in
            guard let newValue else { return }
            viewModel.centerCamera(on: newValue.coordinate)
        }
    }

    private var mapControlsOverlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                GlassEffectContainer {
                    VStack(spacing: 12) {
                        MapPitchToggle(scope: mapScope)
                        MapCompass(scope: mapScope)
                    }
                    .mapControlVisibility(.visible)
                }

                Spacer()

                GlassEffectContainer {
                    VStack(spacing: 12) {
                        MapStyleMenu(mapStyle: $mapStyle)
                        MapUserLocationButton(scope: mapScope)
                    }
                    .mapControlVisibility(.visible)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 150)
        }
    }

    @ViewBuilder
    private var weatherWidgetOverlay: some View {
        if let temperature = weatherService.temperature, let symbolName = weatherService.symbolName {
            VStack {
                HStack {
                    WeatherWidgetView(temperature: temperature, symbolName: symbolName)
                        .padding(.leading, 12)
                        .padding(.top, 8)
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

private struct MapStyleMenu: View {
    @Binding var mapStyle: MapStyle

    var body: some View {
        Menu {
            Button("Standard") { mapStyle = .standard }
            Button("Satellite") { mapStyle = .imagery }
            Button("Hybrid") { mapStyle = .hybrid }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
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
