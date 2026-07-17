import CoreLocation
import MapKit
import Observation

@Observable
@MainActor
final class DirectionsViewModel {
    enum Mode: CaseIterable, Hashable {
        case automobile, walking, transit

        var transportType: MKDirectionsTransportType {
            switch self {
            case .automobile: .automobile
            case .walking: .walking
            case .transit: .transit
            }
        }

        var symbolName: String {
            switch self {
            case .automobile: "car.fill"
            case .walking: "figure.walk"
            case .transit: "tram.fill"
            }
        }

        var label: String {
            switch self {
            case .automobile: "Drive"
            case .walking: "Walk"
            case .transit: "Transit"
            }
        }
    }

    var mode: Mode = .automobile {
        didSet { Task { await calculateRoute() } }
    }
    private(set) var route: MKRoute?
    private(set) var isCalculating = false
    private(set) var errorMessage: String?

    var isActive: Bool { destination != nil }
    var destinationTitle: String { destination?.name ?? "Destination" }

    /// Fired once a route is successfully calculated, so the map can fit its camera to it.
    var onRouteCalculated: ((MKRoute) -> Void)?

    private var destination: MKMapItem?
    private var origin: CLLocation?

    var formattedDistance: String? {
        guard let route else { return nil }
        return Measurement(value: route.distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    var formattedDuration: String? {
        guard let route else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: route.expectedTravelTime)
    }

    func start(destination: MKMapItem, from origin: CLLocation?) async {
        self.destination = destination
        self.origin = origin
        await calculateRoute()
    }

    func stop() {
        destination = nil
        origin = nil
        route = nil
        errorMessage = nil
    }

    private func calculateRoute() async {
        guard let destination, let origin else { return }
        isCalculating = true
        errorMessage = nil
        route = nil

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = destination
        request.transportType = mode.transportType

        do {
            let response = try await MKDirections(request: request).calculate()
            if let calculatedRoute = response.routes.first {
                route = calculatedRoute
                onRouteCalculated?(calculatedRoute)
            } else {
                errorMessage = "No \(mode.label.lowercased()) route found."
            }
        } catch {
            errorMessage = "Couldn't calculate a \(mode.label.lowercased()) route."
        }
        isCalculating = false
    }
}
