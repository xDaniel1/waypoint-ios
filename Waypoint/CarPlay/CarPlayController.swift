import CarPlay
import CoreLocation
import MapKit
import UIKit

/// Everything the car screen does, driving the same engine the phone does.
///
/// `NavigationViewModel` is deliberately shared rather than reimplemented: it already owns step
/// advancement, remaining time and distance, off-route detection and rerouting. CarPlay is a
/// second front-end onto it, so guidance in the car can't drift out of step with guidance on the
/// phone. What lives here is only the translation — our `RouteStep`s into `CPManeuver`s, our
/// `RouteOption` into a `CPTrip`.
@MainActor
final class CarPlayController: NSObject {
    private let interfaceController: CPInterfaceController
    private let mapViewController: CarPlayMapViewController
    private let mapTemplate = CPMapTemplate()

    private let locationManager = LocationManager()
    private let routesService = AppleRoutesService()
    private let navigation = NavigationViewModel()
    private let favorites = FavoritesStore()
    private let recents = RecentSearchesStore()

    private var navigationSession: CPNavigationSession?
    private var activeTrip: CPTrip?
    private var pendingRoute: RouteOption?
    private var pendingDestination: MKMapItem?
    /// Which of the route's steps is currently on the guidance card, so the maneuver is only
    /// rebuilt when it actually changes rather than on every GPS fix.
    private var shownStepIndex: Int?
    private var searchCompletion: (([CPListItem]) -> Void)?
    private var searchResults: [MKMapItem] = []

    init(interfaceController: CPInterfaceController, mapViewController: CarPlayMapViewController) {
        self.interfaceController = interfaceController
        self.mapViewController = mapViewController
        super.init()

        mapTemplate.mapDelegate = self
        configureButtons()
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)

        locationManager.requestPermission()
        Task { await startTrackingLocation() }
    }

    // MARK: - Map template chrome

    private func configureButtons() {
        let recenter = CPMapButton { [weak self] _ in self?.recenter() }
        recenter.image = UIImage(systemName: "location.fill")

        let zoomIn = CPMapButton { [weak self] _ in self?.mapViewController.zoom(by: 0.5) }
        zoomIn.image = UIImage(systemName: "plus.magnifyingglass")

        let zoomOut = CPMapButton { [weak self] _ in self?.mapViewController.zoom(by: 2) }
        zoomOut.image = UIImage(systemName: "minus.magnifyingglass")

        mapTemplate.mapButtons = [recenter, zoomIn, zoomOut]

        // Favorites and recents lead, because they're the two lists a driver can use without
        // typing. Search is there for the cars that offer a keyboard, but it isn't the primary
        // way in.
        mapTemplate.leadingNavigationBarButtons = [
            CPBarButton(title: "Favorites") { [weak self] _ in self?.presentFavorites() },
            CPBarButton(title: "Recents") { [weak self] _ in self?.presentRecents() },
        ]
        mapTemplate.trailingNavigationBarButtons = [
            CPBarButton(title: "Search") { [weak self] _ in self?.presentSearch() },
        ]
    }

    func updateSafeArea(_ insets: UIEdgeInsets) {
        mapViewController.applySafeArea(insets)
    }

    private func recenter() {
        guard let location = locationManager.currentLocation else { return }
        if navigation.isActive {
            mapViewController.follow(location, heading: locationManager.currentHeading)
        } else {
            mapViewController.center(on: location)
        }
    }

    // MARK: - Location

    private func startTrackingLocation() async {
        await locationManager.startUpdating { [weak self] location in
            Task { @MainActor in self?.handle(location) }
        }
    }

    private func handle(_ location: CLLocation) {
        guard navigation.isActive else {
            // Before a trip starts, the first fix is what puts the car on the map at all.
            if navigationSession == nil, activeTrip == nil { mapViewController.center(on: location) }
            return
        }
        navigation.update(with: location)
        mapViewController.follow(location, heading: locationManager.currentHeading)
        mapViewController.draw(route: navigation.remainingCoordinates)
        refreshGuidance()
    }

    // MARK: - Destination lists

    private func presentFavorites() {
        let items = favorites.favorites.map { favorite -> CPListItem in
            let item = CPListItem(text: favorite.displayTitle, detailText: favorite.subtitle)
            item.handler = { [weak self] _, completion in
                self?.previewTrip(to: favorite.coordinate, named: favorite.displayTitle)
                completion()
            }
            return item
        }
        push(list: items, title: "Favorites", emptyMessage: "No favorites yet")
    }

    private func presentRecents() {
        let items = recents.recents.map { recent -> CPListItem in
            let item = CPListItem(text: recent.title, detailText: recent.subtitle)
            item.handler = { [weak self] _, completion in
                self?.previewTrip(to: recent.coordinate, named: recent.title)
                completion()
            }
            return item
        }
        push(list: items, title: "Recents", emptyMessage: "No recent searches yet")
    }

    private func push(list items: [CPListItem], title: String, emptyMessage: String) {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        // Says the list is empty rather than pushing a blank screen the driver has to interpret.
        template.emptyViewTitleVariants = [emptyMessage]
        template.emptyViewSubtitleVariants = ["Add one on your iPhone."]
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func presentSearch() {
        let template = CPSearchTemplate()
        template.delegate = self
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Trip preview

    private func previewTrip(to coordinate: CLLocationCoordinate2D, named name: String) {
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        destination.name = name
        previewTrip(to: destination)
    }

    private func previewTrip(to destination: MKMapItem) {
        guard let origin = locationManager.currentLocation?.coordinate else {
            presentAlert("Waiting for your location.")
            return
        }
        Task {
            do {
                let routes = try await routesService.computeRoutes(
                    from: origin, to: destination, transportType: .automobile
                )
                guard let route = routes.first else {
                    presentAlert("No route to \(destination.name ?? "there").")
                    return
                }
                showPreview(of: route, to: destination, from: origin)
            } catch {
                presentAlert("Couldn't get directions right now.")
            }
        }
    }

    private func showPreview(of route: RouteOption, to destination: MKMapItem, from origin: CLLocationCoordinate2D) {
        pendingRoute = route
        pendingDestination = destination

        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        let choice = CPRouteChoice(
            summaryVariants: [route.summary.isEmpty ? "Fastest route" : route.summary],
            additionalInformationVariants: ["\(route.formattedDuration) · \(route.formattedDistance)"],
            selectionSummaryVariants: [route.formattedDuration]
        )
        let trip = CPTrip(origin: originItem, destination: destination, routeChoices: [choice])
        activeTrip = trip

        mapViewController.draw(route: route.coordinates)
        mapViewController.showWholeRoute()

        let text = CPTripPreviewTextConfiguration(
            startButtonTitle: "Go",
            additionalRoutesButtonTitle: nil,
            overviewButtonTitle: "Overview"
        )
        mapTemplate.showTripPreviews([trip], textConfiguration: text)
    }

    private func presentAlert(_ message: String) {
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            }]
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Guidance

    private func beginNavigation(with trip: CPTrip) {
        guard let route = pendingRoute, let destination = pendingDestination else { return }
        mapTemplate.hideTripPreviews()

        navigation.start(
            route: route,
            destinationName: destination.name ?? "Destination",
            destinationCoordinate: destination.placemark.coordinate
        )
        navigationSession = mapTemplate.startNavigationSession(for: trip)
        shownStepIndex = nil
        mapViewController.draw(route: route.coordinates)
        if let location = locationManager.currentLocation {
            mapViewController.follow(location, heading: locationManager.currentHeading)
        }
        refreshGuidance()
    }

    private func refreshGuidance() {
        guard let session = navigationSession, let trip = activeTrip else { return }

        let estimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: navigation.remainingDistance, unit: UnitLength.meters),
            timeRemaining: navigation.remainingTime
        )
        mapTemplate.update(estimates, for: trip, with: .default)

        // Only rebuild the maneuver card when the step actually changes — otherwise every GPS fix
        // replaces the card and CarPlay re-animates it.
        if shownStepIndex != navigation.currentStepIndex {
            shownStepIndex = navigation.currentStepIndex
            if let step = navigation.currentStep {
                session.upcomingManeuvers = [maneuver(for: step, following: navigation.nextStep)]
            }
        }

        // On the last step there's no "next maneuver" to measure to, so the card counts down the
        // distance to the destination itself rather than showing nothing.
        if let maneuver = session.upcomingManeuvers.first {
            let metres = navigation.distanceToNextManeuver ?? navigation.remainingDistance
            session.updateEstimates(
                CPTravelEstimates(
                    distanceRemaining: Measurement(value: metres, unit: UnitLength.meters),
                    timeRemaining: navigation.remainingTime
                ),
                for: maneuver
            )
        }

        if navigation.hasArrived {
            session.finishTrip()
            endNavigation()
        }
    }

    private func maneuver(for step: RouteStep, following next: RouteStep?) -> CPManeuver {
        let maneuver = CPManeuver()
        // Long form first, short fallbacks after: CarPlay picks whichever fits the car's screen,
        // and a car with a narrow guidance card gets the truncated one rather than clipped text.
        var variants = [step.instruction]
        if let next { variants.append("\(step.instruction) — then \(next.instruction)") }
        maneuver.instructionVariants = variants
        if let symbol = UIImage(systemName: step.maneuverIcon) {
            maneuver.symbolImage = symbol
        }
        maneuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: step.distanceMeters, unit: UnitLength.meters),
            timeRemaining: navigation.remainingTime
        )
        return maneuver
    }

    private func endNavigation() {
        navigationSession = nil
        activeTrip = nil
        pendingRoute = nil
        pendingDestination = nil
        shownStepIndex = nil
        navigation.end()
        mapViewController.clearRoute()
        if let location = locationManager.currentLocation { mapViewController.center(on: location) }
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlayController: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        beginNavigation(with: trip)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        mapViewController.showWholeRoute()
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        navigationSession?.cancelTrip()
        endNavigation()
    }
}

// MARK: - CPSearchTemplateDelegate

extension CarPlayController: CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        guard searchText.count >= 2 else {
            searchResults = []
            completionHandler([])
            return
        }
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = searchText
            if let location = locationManager.currentLocation {
                request.region = MKCoordinateRegion(
                    center: location.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000
                )
            }
            let response = try? await MKLocalSearch(request: request).start()
            // CarPlay caps how many rows a car will show while moving, so this is trimmed here
            // rather than handing over a list the system silently truncates.
            let items = Array((response?.mapItems ?? []).prefix(12))
            searchResults = items
            completionHandler(items.map { item in
                CPListItem(text: item.name ?? "Place", detailText: item.placemark.title)
            })
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        // CPListItem carries no identifier of its own, so the row is matched back to the map item
        // by the text it was built from.
        if let match = searchResults.first(where: { $0.name == item.text }) {
            interfaceController.popToRootTemplate(animated: true) { [weak self] _, _ in
                self?.previewTrip(to: match)
            }
        }
        completionHandler()
    }
}
