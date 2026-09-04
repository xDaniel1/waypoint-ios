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
            switch self {
            case .automobile: return .automobile
            case .walking: return .walking
            case .transit: return .transit
            case .cycling: return .automobile // MapKit doesn't have cycling yet in older iOS
            }
        }

        var mapKitCanRoute: Bool {
            self == .automobile || self == .walking || self == .transit
        }
    }

    var mode: Mode = .automobile {
        didSet { scheduleCalculation() }
    }

    var avoidTolls = false {
        didSet { scheduleCalculation() }
    }
    var avoidHighways = false {
        didSet { scheduleCalculation() }
    }
    var avoidFerries = false {
        didSet { scheduleCalculation() }
    }
    
    var departureDate: Date? {
        didSet { scheduleCalculation() }
    }
    
    var arrivalDate: Date? {
        didSet { scheduleCalculation() }
    }

    var avoidSummary: String {
        let active = [
            avoidTolls ? "Tolls" : nil,
            avoidHighways ? "Highways" : nil,
            avoidFerries ? "Ferries" : nil,
        ].compactMap { $0 }
        switch active.count {
        case 0: return "Avoid"
        case 1: return "Avoid \(active[0])"
        default: return "Avoid (\(active.count))"
        }
    }

    var hasAvoidPreferences: Bool {
        avoidTolls || avoidHighways || avoidFerries
    }

    private(set) var routeOptions: [RouteOption] = []
    private(set) var selectedRouteID: RouteOption.ID?
    private(set) var isCalculating = false
    private(set) var errorMessage: String?
    private(set) var stops: [RouteStop] = []
    /// True while the stop order is being worked out, so the button can spin rather than look dead
    /// — the matrix of pairwise ETAs behind it is a real round trip per pair.
    private(set) var isOptimizingStops = false
    /// Set when a reorder was asked for and the order already in the card was the best one, so the
    /// card can say so instead of appearing to have ignored the tap.
    private(set) var stopOrderNotice: String?

    var isActive: Bool { destination != nil }
    var destinationTitle: String { destination?.name ?? "Destination" }
    var originCoordinate: CLLocationCoordinate2D? { origin?.coordinate }

    var selectedRoute: RouteOption? {
        routeOptions.first { $0.id == selectedRouteID } ?? routeOptions.first
    }

    var onRoutesChanged: (([RouteOption], RouteOption?) -> Void)?
    /// Where the routing gets the list of spots to steer around. Supplied by the screen that owns
    /// the incident layer rather than held here, so this view model doesn't have to know reports
    /// exist to calculate a route.
    var reportedIncidentCoordinates: (() -> [CLLocationCoordinate2D])?

    private var destination: MKMapItem?
    private var origin: CLLocation?
    private var calcTask: Task<Void, Never>?
    private let routesService = AppleRoutesService()
    private let transitService = GoogleTransitService()

    func start(destination: MKMapItem, from origin: CLLocation?) {
        self.destination = destination
        self.origin = origin
        if !mode.mapKitCanRoute {
            mode = .automobile
        } else {
            scheduleCalculation()
        }
    }

    func updateOrigin(_ location: CLLocation) {
        guard destination != nil, origin == nil else { return }
        origin = location
        scheduleCalculation()
    }

    func stop() {
        calcTask?.cancel()
        destination = nil
        origin = nil
        stops = []
        stopOrderNotice = nil
        routeOptions = []
        selectedRouteID = nil
        errorMessage = nil
        onRoutesChanged?([], nil)
    }

    func addStop(_ item: MKMapItem) {
        stops.append(RouteStop(mapItem: item))
        stopOrderNotice = nil
        scheduleCalculation()
    }

    func removeStop(_ stop: RouteStop) {
        stops.removeAll { $0.id == stop.id }
        stopOrderNotice = nil
        scheduleCalculation()
    }

    func moveStops(fromOffsets: IndexSet, toOffset: Int) {
        stops.move(fromOffsets: fromOffsets, toOffset: toOffset)
        scheduleCalculation()
    }

    /// Reorders the stops into the quickest way round them all, keeping the origin where you are
    /// and the destination last.
    ///
    /// Explicitly asked for rather than applied automatically: the order someone typed often
    /// carries a reason the map can't see (the pharmacy shuts first), and Apple doesn't reshuffle
    /// a trip on its own either.
    func optimizeStopOrder() async {
        guard let destination, let origin, stops.count > 1, !isOptimizingStops else { return }
        isOptimizingStops = true
        stopOrderNotice = nil
        defer { isOptimizingStops = false }

        let order = try? await routesService.optimizedStopOrder(
            from: origin.coordinate,
            through: stops.map(\.mapItem),
            to: destination,
            transportType: mode.mkTransportType,
            avoidTolls: avoidTolls,
            avoidHighways: avoidHighways
        )

        guard let order, order.count == stops.count else {
            stopOrderNotice = "This is already the quickest order."
            return
        }
        stops = order.map { stops[$0] }
        Haptics.success()
        scheduleCalculation()
    }

    private func scheduleCalculation() {
        calcTask?.cancel()
        calcTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await calculateRoutes()
        }
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

        do {
            let options: [RouteOption]
            if mode == .transit {
                // MapKit can't do this at all — `MKDirections.calculate()` never returns transit
                // routes, so this mode always failed until it was moved to Google.
                options = try await transitService.routes(
                    from: origin.coordinate,
                    to: destination.placemark.coordinate,
                    departureDate: departureDate
                )
            } else {
                options = try await routesService.computeRoutes(
                    from: origin.coordinate,
                    to: destination,
                    stops: stops.map(\.mapItem),
                    transportType: mode.mkTransportType,
                    avoidTolls: avoidTolls,
                    avoidHighways: avoidHighways,
                    departureDate: departureDate,
                    arrivalDate: arrivalDate,
                    avoiding: reportedIncidentCoordinates?() ?? []
                )
            }
            applyOptions(options, emptyMessage: "No \(mode.label.lowercased()) route found.")
        } catch {
            errorMessage = "Couldn't calculate a \(mode.label.lowercased()) route."
        }

        if Task.isCancelled { return }
        isCalculating = false
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