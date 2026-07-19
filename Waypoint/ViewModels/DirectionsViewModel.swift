import CoreLocation
import MapKit
import Observation

@Observable
@MainActor
final class DirectionsViewModel {
    enum Mode: CaseIterable, Hashable {
        case automobile, walking, transit, cycling

        var symbolName: String {
            switch self {
            case .automobile: "car.fill"
            case .walking: "figure.walk"
            case .transit: "tram.fill"
            case .cycling: "bicycle"
            }
        }

        var label: String {
            switch self {
            case .automobile: "Drive"
            case .walking: "Walk"
            case .transit: "Transit"
            case .cycling: "Bike"
            }
        }

        var mkTransportType: MKDirectionsTransportType {
            self == .walking ? .walking : .automobile
        }

        /// MapKit can only fall back for drive/walk; transit and cycling are Google-only.
        var mapKitCanRoute: Bool {
            self == .automobile || self == .walking
        }

        var googleMode: GoogleRoutesService.Mode {
            switch self {
            case .automobile: .drive
            case .walking: .walk
            case .transit: .transit
            case .cycling: .bicycle
            }
        }
    }

    var mode: Mode = .automobile {
        didSet { scheduleCalculation() }
    }

    private(set) var routeOptions: [RouteOption] = []
    private(set) var selectedRouteID: RouteOption.ID?
    private(set) var isCalculating = false
    private(set) var errorMessage: String?

    var isActive: Bool { destination != nil }
    var destinationTitle: String { destination?.name ?? "Destination" }

    var selectedRoute: RouteOption? {
        routeOptions.first { $0.id == selectedRouteID } ?? routeOptions.first
    }

    /// Fired whenever the drawn routes change, so the map can fit its camera to the selection.
    var onRoutesChanged: (([RouteOption], RouteOption?) -> Void)?

    private var destination: MKMapItem?
    private var origin: CLLocation?
    private let routesService = GoogleRoutesService()
    private var calcTask: Task<Void, Never>?

    func start(destination: MKMapItem, from origin: CLLocation?) {
        self.destination = destination
        self.origin = origin
        if mode != .automobile {
            mode = .automobile // triggers scheduleCalculation via didSet
        } else {
            scheduleCalculation()
        }
    }

    /// Called when the user's location becomes available after directions were requested.
    func updateOrigin(_ location: CLLocation) {
        guard destination != nil, origin == nil else { return }
        origin = location
        scheduleCalculation()
    }

    func stop() {
        calcTask?.cancel()
        destination = nil
        origin = nil
        routeOptions = []
        selectedRouteID = nil
        errorMessage = nil
        onRoutesChanged?([], nil)
    }

    private func scheduleCalculation() {
        calcTask?.cancel()
        calcTask = Task { await calculateRoutes() }
    }

    func select(_ option: RouteOption) {
        selectedRouteID = option.id
        onRoutesChanged?(routeOptions, selectedRoute)
    }

    private func calculateRoutes() async {
        guard let destination else { return }
        guard let origin else {
            errorMessage = "Finding your location…"
            return
        }
        isCalculating = true
        errorMessage = nil
        routeOptions = []
        selectedRouteID = nil
        onRoutesChanged?([], nil)

        // Prefer Google (traffic-aware, alternates, transit/bike); fall back to MapKit for drive/walk.
        let googleOptions = await tryGoogleRoutes(
            origin: origin.coordinate,
            destination: destination.placemark.coordinate
        )
        if Task.isCancelled { return }
        if let googleOptions, !googleOptions.isEmpty {
            applyOptions(googleOptions, emptyMessage: "No \(mode.label.lowercased()) route found.")
        } else if mode.mapKitCanRoute {
            await calculateMapKitRoutes(origin: origin.coordinate, destination: destination)
        } else if errorMessage == nil {
            errorMessage = "No \(mode.label.lowercased()) route found."
        }

        if Task.isCancelled { return }
        isCalculating = false
    }

    /// Returns Google routes, or nil if Google is unavailable (so the caller can fall back).
    private func tryGoogleRoutes(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) async -> [RouteOption]? {
        do {
            return try await routesService.computeRoutes(from: origin, to: destination, mode: mode.googleMode)
        } catch GoogleRoutesError.apiNotEnabled {
            if !mode.mapKitCanRoute {
                errorMessage = "Enable the Google Routes API on your Cloud project to see \(mode.label.lowercased()) routes."
            }
            return nil
        } catch {
            return nil
        }
    }

    private func calculateMapKitRoutes(origin: CLLocationCoordinate2D, destination: MKMapItem) async {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = destination
        request.transportType = mode.mkTransportType
        request.requestsAlternateRoutes = true

        do {
            let response = try await MKDirections(request: request).calculate()
            let options = response.routes.map { route in
                RouteOption(
                    coordinates: route.coordinates,
                    travelTime: route.expectedTravelTime,
                    distanceMeters: route.distance,
                    summary: route.name.isEmpty ? "\(mode.label) route" : "via \(route.name)",
                    transitSteps: []
                )
            }
            applyOptions(options, emptyMessage: "No \(mode.label.lowercased()) route found.")
        } catch {
            errorMessage = "Couldn't calculate a \(mode.label.lowercased()) route."
        }
    }

    private func applyOptions(_ options: [RouteOption], emptyMessage: String) {
        guard !options.isEmpty else {
            errorMessage = emptyMessage
            return
        }
        routeOptions = options
        selectedRouteID = options.first?.id
        onRoutesChanged?(options, options.first)
    }
}
