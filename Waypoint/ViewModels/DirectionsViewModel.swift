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

        var usesGoogle: Bool {
            self == .transit || self == .cycling
        }

        var mkTransportType: MKDirectionsTransportType {
            self == .walking ? .walking : .automobile
        }

        var googleMode: GoogleRoutesService.Mode {
            self == .cycling ? .bicycle : .transit
        }
    }

    var mode: Mode = .automobile {
        didSet { Task { await calculateRoutes() } }
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

    func start(destination: MKMapItem, from origin: CLLocation?) async {
        self.destination = destination
        self.origin = origin
        mode = .automobile
        await calculateRoutes()
    }

    func stop() {
        destination = nil
        origin = nil
        routeOptions = []
        selectedRouteID = nil
        errorMessage = nil
        onRoutesChanged?([], nil)
    }

    func select(_ option: RouteOption) {
        selectedRouteID = option.id
        onRoutesChanged?(routeOptions, selectedRoute)
    }

    private func calculateRoutes() async {
        guard let destination, let origin else { return }
        isCalculating = true
        errorMessage = nil
        routeOptions = []
        selectedRouteID = nil
        onRoutesChanged?([], nil)

        if mode.usesGoogle {
            await calculateGoogleRoutes(origin: origin.coordinate, destination: destination.placemark.coordinate)
        } else {
            await calculateMapKitRoutes(origin: origin.coordinate, destination: destination)
        }

        isCalculating = false
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

    private func calculateGoogleRoutes(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) async {
        do {
            let options = try await routesService.computeRoutes(from: origin, to: destination, mode: mode.googleMode)
            applyOptions(options, emptyMessage: "No \(mode.label.lowercased()) route found.")
        } catch GoogleRoutesError.apiNotEnabled {
            errorMessage = "Enable the Google Routes API on your Cloud project to see \(mode.label.lowercased()) routes."
        } catch GoogleRoutesError.missingAPIKey {
            errorMessage = "Add a Google API key to see \(mode.label.lowercased()) routes."
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
