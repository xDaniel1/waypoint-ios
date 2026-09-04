import CoreLocation
import Foundation
import MapKit
import OSLog

/// Transit routing via Google's Routes API.
///
/// This exists because MapKit simply cannot do it: `MKDirections.calculate()` does not return
/// transit routes for `.transit` — Apple only supports transit by handing the trip off to the
/// Maps app with `MKMapItem.openMaps`. So every transit request in this app failed with
/// "Couldn't calculate a transit route" no matter what, and no amount of MapKit tuning would
/// have changed that.
///
/// Google returns the detail the transit UI was already built for and never had a source for:
/// line names and colors, vehicle type (subway/bus/rail), boarding and arrival stops, stop
/// counts, headsigns, and real departure/arrival times.
struct GoogleTransitService {
    private let apiKey = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
    private var isConfigured: Bool { !apiKey.isEmpty }

    /// Transit results are time-sensitive — a cached departure time goes wrong fast — so this is
    /// a much shorter TTL than the place caches. It still collapses the repeat calls you get from
    /// toggling between modes in the directions card.
    private static let cache = DiskCache<CachedRoutes>(name: "transit-routes", ttl: 180)

    func routes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        departureDate: Date?
    ) async throws -> [RouteOption] {
        guard isConfigured else { throw GooglePlacesError.missingAPIKey }

        let key = Self.cacheKey(origin: origin, destination: destination, departureDate: departureDate)
        if let cached = await Self.cache.value(forKey: key) {
            return cached.routes.map(\.routeOption)
        }

        var request = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        GoogleAPIRequest.addBundleIdentifierHeader(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            [
                "routes.duration", "routes.distanceMeters", "routes.polyline.encodedPolyline",
                "routes.description", "routes.legs.steps.transitDetails",
                "routes.legs.steps.travelMode", "routes.legs.steps.staticDuration",
                // Per-step geometry, so each ride can be drawn in its own line's colour rather
                // than the whole trip taking the first ride's. This doesn't move the request to
                // a pricier SKU — `routes.legs.steps.transitDetails` above already puts it in
                // the advanced tier, and step polylines ride along in the same one.
                "routes.legs.steps.polyline.encodedPolyline",
                "routes.travelAdvisory.transitFare",
            ].joined(separator: ","),
            forHTTPHeaderField: "X-Goog-FieldMask"
        )

        var body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": origin.latitude, "longitude": origin.longitude]]],
            "destination": ["location": ["latLng": ["latitude": destination.latitude, "longitude": destination.longitude]]],
            "travelMode": "TRANSIT",
            "computeAlternativeRoutes": true,
        ]
        if let departureDate, departureDate > Date() {
            body["departureTime"] = Formatters.iso8601.string(from: departureDate)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            Logger.navigation.error("Transit routing failed (\(status)): \(detail)")
            throw GooglePlacesError.requestFailed(status)
        }

        let decoded = try JSONDecoder().decode(RoutesResponse.self, from: data)
        let parsed = (decoded.routes ?? []).map(ParsedRoute.init)
        guard !parsed.isEmpty else { return [] }

        await Self.cache.store(CachedRoutes(routes: parsed), forKey: key)
        return parsed.map(\.routeOption)
    }

    /// Rounded to ~100m and to the minute: finer precision would fragment the cache and re-bill
    /// for what is effectively the same trip.
    private static func cacheKey(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        departureDate: Date?
    ) -> String {
        func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        let departure = departureDate.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "now"
        return "\(round(origin.latitude)),\(round(origin.longitude))|\(round(destination.latitude)),\(round(destination.longitude))|\(departure)"
    }
}

// MARK: - Wire format

private struct RoutesResponse: Codable {
    let routes: [Route]?

    struct Route: Codable {
        let duration: String?
        let distanceMeters: Int?
        let description: String?
        let polyline: Polyline?
        let legs: [Leg]?
        let travelAdvisory: TravelAdvisory?
    }

    struct Polyline: Codable { let encodedPolyline: String? }
    struct TravelAdvisory: Codable { let transitFare: Money? }
    struct Money: Codable { let currencyCode: String?; let units: String? }
    struct Leg: Codable { let steps: [Step]? }

    struct Step: Codable {
        let travelMode: String?
        let staticDuration: String?
        let transitDetails: TransitDetails?
        let polyline: Polyline?
    }

    struct TransitDetails: Codable {
        let stopDetails: StopDetails?
        let headsign: String?
        let stopCount: Int?
        let transitLine: TransitLine?
    }

    struct StopDetails: Codable {
        let arrivalStop: Stop?
        let arrivalTime: String?
        let departureStop: Stop?
        let departureTime: String?
    }

    struct Stop: Codable { let name: String?; let location: LatLngWrapper? }
    struct LatLngWrapper: Codable { let latLng: LatLngValue? }
    struct LatLngValue: Codable { let latitude: Double?; let longitude: Double? }

    struct TransitLine: Codable {
        let name: String?
        let nameShort: String?
        let color: String?
        let vehicle: Vehicle?
    }

    struct Vehicle: Codable { let type: String?; let name: LocalizedName? }
    struct LocalizedName: Codable { let text: String? }
}

/// Cache-friendly flattening of a route — the app's `RouteOption` isn't `Codable` (it holds
/// MapKit types), so the decoded shape is what gets persisted and rehydrated.
private struct ParsedRoute: Codable {
    var seconds: TimeInterval
    var distanceMeters: Double
    var summary: String
    var encodedPolyline: String
    var fare: String?
    var steps: [ParsedTransitStep]
    var walkMinutes: [Int]
    /// Every step's own geometry, in trip order. Optional so a cache file written before this
    /// existed still decodes — those entries just fall back to the single-colour whole-route
    /// line until their 3-minute TTL expires.
    var stepGeometry: [ParsedStepGeometry]?

    init(_ route: RoutesResponse.Route) {
        seconds = ParsedRoute.parseDuration(route.duration)
        distanceMeters = Double(route.distanceMeters ?? 0)
        encodedPolyline = route.polyline?.encodedPolyline ?? ""

        let allSteps = (route.legs ?? []).flatMap { $0.steps ?? [] }
        steps = allSteps.compactMap { step in
            guard let details = step.transitDetails else { return nil }
            return ParsedTransitStep(details)
        }
        walkMinutes = allSteps.compactMap { step in
            guard step.travelMode == "WALK" else { return nil }
            let minutes = Int(ParsedRoute.parseDuration(step.staticDuration) / 60)
            return minutes > 0 ? minutes : nil
        }
        // Walk the steps once more to pair each stretch of geometry with the ride it belongs to.
        // `transitStepIndex` points back into `steps`, which only holds the rides, so the walks
        // in between carry no index and draw grey.
        var transitStepIndex = 0
        stepGeometry = allSteps.map { step in
            let index: Int?
            if step.transitDetails != nil {
                index = transitStepIndex
                transitStepIndex += 1
            } else {
                index = nil
            }
            return ParsedStepGeometry(
                encodedPolyline: step.polyline?.encodedPolyline ?? "",
                isWalk: step.travelMode == "WALK" || step.transitDetails == nil,
                transitStepIndex: index,
                seconds: ParsedRoute.parseDuration(step.staticDuration)
            )
        }

        summary = steps.first.map { "via \($0.displayLine)" } ?? route.description ?? "Transit"

        if let fareValue = route.travelAdvisory?.transitFare,
           let units = fareValue.units, let amount = Double(units) {
            let code = fareValue.currencyCode ?? "USD"
            fare = code == "USD" ? String(format: "$%.2f", amount) : "\(units) \(code)"
        }
    }

    /// Google returns durations as e.g. "1234s".
    static func parseDuration(_ raw: String?) -> TimeInterval {
        guard let raw, let value = Double(raw.replacingOccurrences(of: "s", with: "")) else { return 0 }
        return value
    }

    var routeOption: RouteOption {
        let transitSteps = steps.map(\.transitStep)
        let split = Self.split(stepGeometry, rides: transitSteps)
        var option = RouteOption(
            // When every step came back with geometry, the route's coordinates *are* the legs
            // stitched together — which keeps the indices `TransitSegment.range` refers to and
            // the ones navigation tracks progress with as the same numbers. Otherwise fall back
            // to the whole-route polyline and let the map draw one tinted line.
            coordinates: split.isEmpty ? PolylineDecoder.decode(encodedPolyline) : split.coordinates,
            travelTime: seconds,
            distanceMeters: distanceMeters,
            summary: summary,
            transitSteps: transitSteps
        )
        option.transitSegments = split.segments
        option.fare = fare
        option.transitStops = steps.flatMap(\.namedStops)
        // Walk legs first, then each ride, in the order Google returned them.
        option.transitLegs = zip(walkMinutes, transitSteps).flatMap {
            [DirectionsLeg.walk(minutes: $0.0), DirectionsLeg.transit($0.1)]
        }
        if option.transitLegs.isEmpty {
            option.transitLegs = transitSteps.map { DirectionsLeg.transit($0) }
        }
        option.departureText = steps.first?.departureText
        return option
    }
}

/// One step's raw geometry plus which ride (if any) it belongs to.
private struct ParsedStepGeometry: Codable {
    var encodedPolyline: String
    var isWalk: Bool
    var transitStepIndex: Int?
    /// Google's own estimate for this step alone. Optional so cache files written before this
    /// existed still decode; navigation falls back to distance-proportional timing without it.
    var seconds: Double?
}

extension ParsedRoute {
    /// Stitches the per-step polylines into one coordinate array and records which slice of it
    /// each leg occupies.
    ///
    /// Returns empty when any step is missing geometry — a partially-coloured route would draw
    /// with gaps where the missing steps were, which is worse than one honest solid line.
    static func split(
        _ geometry: [ParsedStepGeometry]?,
        rides: [TransitStep]
    ) -> (coordinates: [CLLocationCoordinate2D], segments: [TransitSegment], isEmpty: Bool) {
        guard let geometry, !geometry.isEmpty,
              geometry.allSatisfy({ !$0.encodedPolyline.isEmpty }) else {
            return ([], [], true)
        }

        var merged: [CLLocationCoordinate2D] = []
        var segments: [TransitSegment] = []

        for step in geometry {
            var coordinates = PolylineDecoder.decode(step.encodedPolyline)
            // Consecutive steps repeat the coordinate they meet at; keeping both would leave a
            // zero-length hop between legs.
            if let tail = merged.last, let head = coordinates.first, isSamePoint(tail, head) {
                coordinates.removeFirst()
            }
            guard !coordinates.isEmpty else { continue }

            let start = merged.count
            merged.append(contentsOf: coordinates)
            let ride = step.transitStepIndex.flatMap { rides.indices.contains($0) ? rides[$0] : nil }
            segments.append(
                TransitSegment(
                    // Reach back one point into the previous leg so the colours butt up against
                    // each other instead of leaving a hairline gap at the transfer.
                    coordinates: Array(merged[max(0, start - 1)..<merged.count]),
                    range: start..<merged.count,
                    isWalk: ride == nil,
                    lineLabel: ride?.displayLine,
                    providerColor: ride?.color,
                    isSubway: ride?.isSubway ?? false,
                    rideIndex: ride == nil ? nil : step.transitStepIndex,
                    seconds: step.seconds
                )
            )
        }

        guard merged.count > 1, !segments.isEmpty else { return ([], [], true) }
        return (merged, segments, false)
    }

    /// ~1cm at NYC latitudes — tight enough that only a genuinely repeated joint matches.
    private static func isSamePoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7
    }
}

private struct ParsedTransitStep: Codable {
    var lineName: String
    var lineShortName: String?
    var vehicle: String
    var departureStop: String
    var arrivalStop: String
    var numStops: Int?
    var headsign: String?
    var color: String?
    var departureISO: String?
    var arrivalISO: String?
    var departureLat: Double?
    var departureLng: Double?
    var arrivalLat: Double?
    var arrivalLng: Double?

    init(_ details: RoutesResponse.TransitDetails) {
        let line = details.transitLine
        lineName = line?.name ?? line?.vehicle?.name?.text ?? "Transit"
        lineShortName = line?.nameShort
        vehicle = line?.vehicle?.type ?? "TRANSIT"
        departureStop = details.stopDetails?.departureStop?.name ?? ""
        arrivalStop = details.stopDetails?.arrivalStop?.name ?? ""
        numStops = details.stopCount
        headsign = details.headsign
        color = line?.color
        departureISO = details.stopDetails?.departureTime
        arrivalISO = details.stopDetails?.arrivalTime
        departureLat = details.stopDetails?.departureStop?.location?.latLng?.latitude
        departureLng = details.stopDetails?.departureStop?.location?.latLng?.longitude
        arrivalLat = details.stopDetails?.arrivalStop?.location?.latLng?.latitude
        arrivalLng = details.stopDetails?.arrivalStop?.location?.latLng?.longitude
    }

    var displayLine: String { lineShortName ?? lineName }

    var transitStep: TransitStep {
        TransitStep(
            lineName: lineName,
            lineShortName: lineShortName,
            vehicle: vehicle,
            departureStop: departureStop,
            arrivalStop: arrivalStop,
            numStops: numStops,
            headsign: headsign,
            color: color,
            departureISO: departureISO,
            arrivalISO: arrivalISO
        )
    }

    var namedStops: [NamedStop] {
        var stops: [NamedStop] = []
        if let lat = departureLat, let lng = departureLng, !departureStop.isEmpty {
            stops.append(NamedStop(name: departureStop, coordinate: .init(latitude: lat, longitude: lng)))
        }
        if let lat = arrivalLat, let lng = arrivalLng, !arrivalStop.isEmpty {
            stops.append(NamedStop(name: arrivalStop, coordinate: .init(latitude: lat, longitude: lng)))
        }
        return stops
    }

    /// "Departs 7:49 PM" — only when Google actually gave a departure time.
    var departureText: String? {
        guard let departureISO, let date = Formatters.iso8601.date(from: departureISO) else { return nil }
        return "Departs \(Formatters.clockTime.string(from: date))"
    }
}

private struct CachedRoutes: Codable {
    let routes: [ParsedRoute]
}

/// Google encodes route geometry with its own polyline algorithm.
enum PolylineDecoder {
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0, lng = 0

        while index < encoded.endIndex {
            func nextValue() -> Int? {
                var result = 0, shift = 0, byte = 0
                repeat {
                    guard index < encoded.endIndex,
                          let ascii = encoded[index].asciiValue else { return nil }
                    byte = Int(ascii) - 63
                    result |= (byte & 0x1F) << shift
                    shift += 5
                    index = encoded.index(after: index)
                } while byte >= 0x20
                return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            }
            guard let dLat = nextValue(), let dLng = nextValue() else { break }
            lat += dLat
            lng += dLng
            coordinates.append(.init(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
        }
        return coordinates
    }
}
