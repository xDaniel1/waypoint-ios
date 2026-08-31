import CarPlay
import MapKit
import UIKit

/// The map CarPlay draws into. CarPlay hands the app a `CPWindow` on the car's screen and expects
/// a plain UIKit root view controller in it — the templates (buttons, trip previews, the guidance
/// panel) are drawn by the system on top, and this is only responsible for the map underneath.
///
/// `MKMapView` rather than SwiftUI's `Map`: the CarPlay window is UIKit, and the parts that matter
/// here (setting a camera every GPS fix, swapping a route overlay) are direct calls on the map
/// view instead of state changes waiting on a SwiftUI update.
final class CarPlayMapViewController: UIViewController {
    private let mapView = MKMapView()
    private var routeOverlay: MKPolyline?

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        // The car's screen already has its own compass and scale furniture, and the templates
        // overlay the corners these would sit in.
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = true
        view.addSubview(mapView)
    }

    /// CarPlay reports the area not covered by the system's own panels. Insetting the map by it
    /// keeps the user's position and the route out from under the guidance card.
    func applySafeArea(_ insets: UIEdgeInsets) {
        mapView.layoutMargins = insets
    }

    func draw(route coordinates: [CLLocationCoordinate2D]) {
        if let routeOverlay { mapView.removeOverlay(routeOverlay) }
        guard coordinates.count > 1 else { routeOverlay = nil; return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        mapView.addOverlay(polyline, level: .aboveRoads)
        routeOverlay = polyline
    }

    func clearRoute() {
        if let routeOverlay { mapView.removeOverlay(routeOverlay) }
        routeOverlay = nil
    }

    /// Frames the whole trip, for the preview before the driver taps Go.
    func showWholeRoute() {
        guard let routeOverlay else { return }
        mapView.setVisibleMapRect(
            routeOverlay.boundingMapRect,
            edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
            animated: true
        )
    }

    /// The driving camera: tight, tilted, turned to face the direction of travel.
    func follow(_ location: CLLocation, heading: CLLocationDirection?) {
        let camera = MKMapCamera(
            lookingAtCenter: location.coordinate,
            fromDistance: 500,
            pitch: 50,
            heading: heading ?? location.course
        )
        mapView.setCamera(camera, animated: true)
    }

    /// Recenter without the driving tilt — what the map button does when not navigating.
    func center(on location: CLLocation) {
        mapView.setRegion(
            MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200),
            animated: true
        )
    }

    func zoom(by factor: Double) {
        var region = mapView.region
        region.span = MKCoordinateSpan(
            latitudeDelta: min(max(region.span.latitudeDelta * factor, 0.0005), 60),
            longitudeDelta: min(max(region.span.longitudeDelta * factor, 0.0005), 60)
        )
        mapView.setRegion(region, animated: true)
    }
}

extension CarPlayMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.strokeColor = .systemBlue
        renderer.lineWidth = 8
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}
