import CoreLocation
import Foundation

enum GoogleRoutesError: Error {
    case missingAPIKey
    case apiNotEnabled
    case requestFailed(Int)
    case noRoutes
}

/// Google Routes API (computeRoutes) for travel modes MapKit can't do — biking and transit
/// (with train/bus line details). Requires the Routes API enabled on the Cloud project.
struct GoogleRoutesService {
    enum Mode: String {
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
        mode: Mode
    ) async throws -> [RouteOption] {
        guard !apiKey.isEmpty else { throw GoogleRoutesError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.legs.steps.transitDetails,routes.description",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": origin.latitude, "longitude": origin.longitude]]],
            "destination": ["location": ["latLng": ["latitude": destination.latitude, "longitude": destination.longitude]]],
            "travelMode": mode.rawValue,
            "polylineQuality": "HIGH_QUALITY",
        ]
        if mode == .transit {
            body["computeAlternativeRoutes"] = true
        } else {
            body["computeAlternativeRoutes"] = true
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
            let steps = Self.transitSteps(from: route)
            let summary = Self.summary(mode: mode, route: route, steps: steps)
            return RouteOption(
                coordinates: coords,
                travelTime: seconds,
                distanceMeters: Double(route.distanceMeters ?? 0),
                summary: summary,
                transitSteps: steps
            )
        }
    }

    private static func parseDuration(_ value: String?) -> TimeInterval {
        // Google returns e.g. "1234s"
        guard let value, value.hasSuffix("s"), let seconds = Double(value.dropLast()) else { return 0 }
        return seconds
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
                    color: line?.color
                ))
            }
        }
        return steps
    }

    private static func summary(mode: Mode, route: RoutesResponse.Route, steps: [TransitStep]) -> String {
        if mode == .transit {
            let lines = steps.map { $0.displayLine }
            return lines.isEmpty ? "Transit" : lines.joined(separator: " → ")
        }
        return route.description ?? "Bike route"
    }
}

// MARK: - Response models

private struct RoutesResponse: Codable {
    let routes: [Route]?

    struct Route: Codable {
        let duration: String?
        let distanceMeters: Int?
        let description: String?
        let polyline: Polyline?
        let legs: [Leg]?
    }

    struct Polyline: Codable {
        let encodedPolyline: String?
    }

    struct Leg: Codable {
        let steps: [Step]?
    }

    struct Step: Codable {
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
        let departureStop: Stop?
    }

    struct Stop: Codable {
        let name: String?
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
        var index = encoded.startIndex
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

        _ = index
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
