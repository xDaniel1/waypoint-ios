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
            body["departureTime"] = ISO8601DateFormatter().string(from: departureDate)
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
        var option = RouteOption(
            coordinates: PolylineDecoder.decode(encodedPolyline),
            travelTime: seconds,
            distanceMeters: distanceMeters,
            summary: summary,
            transitSteps: transitSteps
        )
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
        guard let departureISO, let date = ISO8601DateFormatter().date(from: departureISO) else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Departs \(formatter.string(from: date))"
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
