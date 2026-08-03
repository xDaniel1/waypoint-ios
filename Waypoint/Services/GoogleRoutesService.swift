import CoreLocation
import Foundation

enum GoogleRoutesError: Error {
    case missingAPIKey
    case apiNotEnabled
    case requestFailed(Int)
    case noRoutes
}

/// Google Routes API (computeRoutes) for all travel modes with traffic-aware driving,
/// alternate routes, turn-by-turn steps, and transit line details.
/// Requires the Routes API enabled on the Cloud project.
struct GoogleRoutesService {
    enum Mode: String {
        case drive = "DRIVE"
        case walk = "WALK"
        case bicycle = "BICYCLE"
        case transit = "TRANSIT"
    }

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey ?? Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
        self.session = session
    }

    func computeRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        mode: Mode,
        avoidTolls: Bool = false,
        avoidHighways: Bool = false,
        avoidFerries: Bool = false,
        intermediates: [CLLocationCoordinate2D] = []
    ) async throws -> [RouteOption] {
        guard !apiKey.isEmpty else { throw GoogleRoutesError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            [
                "routes.duration", "routes.staticDuration", "routes.distanceMeters",
                "routes.polyline.encodedPolyline", "routes.description",
                "routes.travelAdvisory.transitFare", "routes.travelAdvisory.speedReadingIntervals",
                "routes.legs.steps.navigationInstruction", "routes.legs.steps.distanceMeters",
                "routes.legs.steps.travelMode", "routes.legs.steps.staticDuration",
                "routes.legs.steps.transitDetails",
            ].joined(separator: ","),
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12

        var body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": origin.latitude, "longitude": origin.longitude]]],
            "destination": ["location": ["latLng": ["latitude": destination.latitude, "longitude": destination.longitude]]],
            "travelMode": mode.rawValue,
            "polylineQuality": "HIGH_QUALITY",
            // Alternates and waypoints don't mix in Google's API — a route through required
            // stops has exactly one shape, so alternates only make sense with zero stops.
            "computeAlternativeRoutes": intermediates.isEmpty,
        ]
        if !intermediates.isEmpty {
            body["intermediates"] = intermediates.map {
                ["location": ["latLng": ["latitude": $0.latitude, "longitude": $0.longitude]]]
            }
        }
        if mode == .drive {
            // Live-traffic-aware routing so ETAs reflect current congestion and closures.
            body["routingPreference"] = "TRAFFIC_AWARE_OPTIMAL"
        }
        // Route modifiers only apply to driving/two-wheeler routes in Google's API.
        if mode == .drive, avoidTolls || avoidHighways || avoidFerries {
            body["routeModifiers"] = [
                "avoidTolls": avoidTolls,
                "avoidHighways": avoidHighways,
                "avoidFerries": avoidFerries,
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 403 {
            throw GoogleRoutesError.apiNotEnabled
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleRoutesError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(RoutesResponse.self, from: data)
        guard let routes = decoded.routes, !routes.isEmpty else { throw GoogleRoutesError.noRoutes }

        return routes.compactMap { route in
            guard let encoded = route.polyline?.encodedPolyline else { return nil }
            let coords = PolylineDecoder.decode(encoded)
            guard !coords.isEmpty else { return nil }
            let seconds = Self.parseDuration(route.duration)
            let staticSeconds = Self.parseDuration(route.staticDuration)
            let transit = Self.transitSteps(from: route)
            let steps = Self.navSteps(from: route)
            let summary = Self.summary(mode: mode, route: route, transit: transit)
            var option = RouteOption(
                coordinates: coords,
                travelTime: seconds,
                distanceMeters: Double(route.distanceMeters ?? 0),
                summary: summary,
                transitSteps: transit,
                steps: steps,
                hasTraffic: mode == .drive && seconds > staticSeconds + 60,
                congestionSegments: mode == .drive
                    ? Self.congestionSegments(from: route.travelAdvisory?.speedReadingIntervals, coordinates: coords)
                    : []
            )
            if mode == .transit {
                option.transitLegs = Self.transitLegs(from: route)
                option.fare = Self.fareString(from: route)
                option.departureText = Self.departureText(from: transit)
                option.transitStops = Self.namedStops(from: route)
            }
            return option
        }
    }

    /// Slices the route's coordinate array into colored overlay segments wherever Google marked
    /// traffic as slower than free-flow. `NORMAL` (and unset) intervals are dropped — there's
    /// nothing worth drawing over the base route line for those.
    private static func congestionSegments(
        from intervals: [RoutesResponse.SpeedReadingInterval]?, coordinates: [CLLocationCoordinate2D]
    ) -> [CongestionSegment] {
        guard let intervals, !coordinates.isEmpty else { return [] }
        var segments: [CongestionSegment] = []
        for interval in intervals {
            let severity: CongestionSegment.Severity
            switch interval.speed {
            case "SLOW": severity = .slow
            case "TRAFFIC_JAM": severity = .jam
            default: continue
            }
            let start = max(0, interval.startPolylinePointIndex ?? 0)
            let end = min(coordinates.count - 1, interval.endPolylinePointIndex ?? coordinates.count - 1)
            guard start < end else { continue }
            segments.append(CongestionSegment(coordinates: Array(coordinates[start...end]), severity: severity))
        }
        return segments
    }

    private static func parseDuration(_ value: String?) -> TimeInterval {
        guard let value, value.hasSuffix("s"), let seconds = Double(value.dropLast()) else { return 0 }
        return seconds
    }

    private static func navSteps(from route: RoutesResponse.Route) -> [RouteStep] {
        var steps: [RouteStep] = []
        for leg in route.legs ?? [] {
            for step in leg.steps ?? [] {
                if let instruction = step.navigationInstruction?.instructions, !instruction.isEmpty {
                    steps.append(RouteStep(instruction: instruction, distanceMeters: Double(step.distanceMeters ?? 0)))
                }
            }
        }
        return steps
    }

    /// Ordered walk/transit legs; consecutive walk sub-steps are merged into one walk leg.
    private static func transitLegs(from route: RoutesResponse.Route) -> [DirectionsLeg] {
        var legs: [DirectionsLeg] = []
        var walkSeconds = 0.0
        func flushWalk() {
            if walkSeconds > 0 {
                let minutes = max(1, Int((walkSeconds / 60).rounded()))
                legs.append(.walk(minutes: minutes))
                walkSeconds = 0
            }
        }
        for leg in route.legs ?? [] {
            for step in leg.steps ?? [] {
                if let td = step.transitDetails {
                    flushWalk()
                    let line = td.transitLine
                    legs.append(.transit(TransitStep(
                        lineName: line?.name ?? line?.nameShort ?? "Transit",
                        lineShortName: line?.nameShort,
                        vehicle: line?.vehicle?.type ?? "TRANSIT",
                        departureStop: td.stopDetails?.departureStop?.name ?? "—",
                        arrivalStop: td.stopDetails?.arrivalStop?.name ?? "—",
                        numStops: td.stopCount,
                        headsign: td.headsign,
                        color: line?.color
                    )))
                } else if step.travelMode == "WALK" {
                    walkSeconds += parseDuration(step.staticDuration)
                }
            }
        }
        flushWalk()
        return legs
    }

    private static func fareString(from route: RoutesResponse.Route) -> String? {
        guard let fare = route.travelAdvisory?.transitFare,
              let units = fare.units, let amount = Double(units) else { return nil }
        let code = fare.currencyCode ?? "USD"
        return amount.formatted(.currency(code: code))
    }

    private static func departureText(from transit: [TransitStep]) -> String? {
        guard let first = transit.first, let iso = first.departureISO else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return nil }
        let minutes = Int(date.timeIntervalSinceNow / 60)
        let verb = first.vehicle.uppercased().contains("BUS") ? "Bus" : "Train"
        if minutes <= 0 { return "\(verb) departs now" }
        if minutes <= 20 { return "\(verb) departs in \(minutes) min" }
        return "Leave by \(date.formatted(date: .omitted, time: .shortened))"
    }

    private static func namedStops(from route: RoutesResponse.Route) -> [NamedStop] {
        var stops: [NamedStop] = []
        for leg in route.legs ?? [] {
            for step in leg.steps ?? [] {
                guard let td = step.transitDetails else { continue }
                for stop in [td.stopDetails?.departureStop, td.stopDetails?.arrivalStop] {
                    if let stop, let loc = stop.location?.latLng, let name = stop.name {
                        stops.append(NamedStop(
                            name: name,
                            coordinate: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                        ))
                    }
                }
            }
        }
        return stops
    }

    private static func transitSteps(from route: RoutesResponse.Route) -> [TransitStep] {
        var steps: [TransitStep] = []
        for leg in route.legs ?? [] {
            for step in leg.steps ?? [] {
                guard let td = step.transitDetails else { continue }
                let line = td.transitLine
                steps.append(TransitStep(
                    lineName: line?.name ?? line?.nameShort ?? "Transit",
                    lineShortName: line?.nameShort,
                    vehicle: line?.vehicle?.type ?? "TRANSIT",
                    departureStop: td.stopDetails?.departureStop?.name ?? "—",
                    arrivalStop: td.stopDetails?.arrivalStop?.name ?? "—",
                    numStops: td.stopCount,
                    headsign: td.headsign,
                    color: line?.color,
                    departureISO: td.stopDetails?.departureTime
                ))
            }
        }
        return steps
    }

    private static func summary(mode: Mode, route: RoutesResponse.Route, transit: [TransitStep]) -> String {
        if mode == .transit {
            let lines = transit.map { $0.displayLine }
            return lines.isEmpty ? "Transit" : lines.joined(separator: " → ")
        }
        if let desc = route.description, !desc.isEmpty { return "via \(desc)" }
        return "\(mode.rawValue.capitalized) route"
    }
}

// MARK: - Response models

private struct RoutesResponse: Codable {
    let routes: [Route]?

    struct Route: Codable {
        let duration: String?
        let staticDuration: String?
        let distanceMeters: Int?
        let description: String?
        let polyline: Polyline?
        let legs: [Leg]?
        let travelAdvisory: TravelAdvisory?
    }

    struct TravelAdvisory: Codable {
        let transitFare: Fare?
        let speedReadingIntervals: [SpeedReadingInterval]?
    }

    /// A [startPolylinePointIndex, endPolylinePointIndex) slice of the route's polyline and how
    /// fast traffic is actually moving through it. Google omits `startPolylinePointIndex` when
    /// an interval starts at the beginning of the polyline, and `speed` when unset defaults to
    /// normal (nothing worth drawing).
    struct SpeedReadingInterval: Codable {
        let startPolylinePointIndex: Int?
        let endPolylinePointIndex: Int?
        let speed: String?
    }

    struct Fare: Codable {
        let currencyCode: String?
        let units: String?
    }

    struct Polyline: Codable {
        let encodedPolyline: String?
    }

    struct Leg: Codable {
        let steps: [Step]?
    }

    struct Step: Codable {
        let navigationInstruction: NavInstruction?
        let distanceMeters: Int?
        let travelMode: String?
        let staticDuration: String?
        let transitDetails: TransitDetails?
    }

    struct NavInstruction: Codable {
        let instructions: String?
    }

    struct TransitDetails: Codable {
        let stopDetails: StopDetails?
        let headsign: String?
        let stopCount: Int?
        let transitLine: TransitLine?
    }

    struct StopDetails: Codable {
        let arrivalStop: Stop?
        let departureStop: Stop?
        let departureTime: String?
    }

    struct Stop: Codable {
        let name: String?
        let location: StopLocation?
    }

    struct StopLocation: Codable {
        let latLng: LatLng?
    }

    struct LatLng: Codable {
        let latitude: Double
        let longitude: Double
    }

    struct TransitLine: Codable {
        let name: String?
        let nameShort: String?
        let color: String?
        let vehicle: Vehicle?
    }

    struct Vehicle: Codable {
        let type: String?
    }
}

// MARK: - Encoded polyline decoder (Google's algorithm)

enum PolylineDecoder {
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var lat = 0
        var lng = 0
        let scalars = Array(encoded.unicodeScalars)
        var i = 0

        func nextValue() -> Int {
            var result = 0
            var shift = 0
            while i < scalars.count {
                let byte = Int(scalars[i].value) - 63
                i += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 { break }
            }
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while i < scalars.count {
            lat += nextValue()
            lng += nextValue()
            coordinates.append(
                CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5)
            )
        }
        return coordinates
    }
}
