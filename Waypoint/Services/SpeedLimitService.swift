import CoreLocation
import Foundation
import MapKit
import Observation

/// Posted speed limits, from two real sources — never inferred.
///
/// Why not Google: the Roads API's `speedLimits` method is gated behind an Asset Tracking
/// licence — with billing fully active it still returns `API_KEY_SERVICE_BLOCKED` for
/// `ListSpeedLimits` specifically, so no amount of normal spend unlocks it. MapKit exposes no
/// speed limit API to third-party apps at all.
///
/// 1. **OpenStreetMap** (Overpass API) — worldwide, free, keyless. Good coverage on highways and
///    arterials, but frequently blank on residential streets. Measured directly: McKibbin St in
///    Brooklyn carries no `maxspeed` tag at all, which is why the sign never appeared there.
/// 2. **NYC DOT** (`VZV Speed Limits` on NYC Open Data) — the city's own posted-limit centreline
///    data, which *does* cover those residential streets. Only queried inside NYC's bounding box.
///
/// Both are real posted limits. When neither has data the sign simply doesn't appear — it never
/// guesses or falls back to a default.
///
/// Starting a trip pulls the limits for the road ahead in one go (`prefetch(along:from:)`) and
/// keeps them in a local table. That's what makes the sign survive a tunnel, a dead zone, or a
/// tetchy Overpass — three places where a lookup-per-fix design goes blank exactly when the number
/// matters. Live lookups still run for anything the table missed.
@Observable
@MainActor
final class SpeedLimitService {
    private(set) var speedLimitKph: Int?

    private let session: URLSession
    private var lastFetch: Date = .distantPast
    private var lastCoordinate: CLLocationCoordinate2D?
    private var inFlight: Task<Void, Never>?

    /// Posted limits for the stretch of route already pulled down, so the common case costs no
    /// network at all.
    private var table: [RoadSegment] = []
    /// Where the prefetched stretch runs out, as metres-remaining on the route it was built for.
    /// Once the driver is close to that, the next stretch is pulled.
    private var tableValidUntilMetresRemaining: Double?
    private var prefetchTask: Task<Void, Never>?

    /// One road with a posted limit, kept as its own geometry so a lookup is "which road am I on",
    /// not "what was the answer near here last time".
    private struct RoadSegment {
        let coordinates: [CLLocationCoordinate2D]
        let kph: Int
        /// City data beats OSM where both cover the same street — it's the authority that put the
        /// sign up, and it's the one with the residential coverage.
        let isAuthoritative: Bool
        /// Precomputed so the per-fix lookup can reject a road that's nowhere near the car with
        /// four comparisons instead of walking its geometry. A city block of NYC centrelines is
        /// thousands of segments; projecting onto every one of them, on the main actor, several
        /// times a second, is the kind of thing that quietly costs a frame.
        let bounds: MKMapRect

        init(coordinates: [CLLocationCoordinate2D], kph: Int, isAuthoritative: Bool) {
            self.coordinates = coordinates
            self.kph = kph
            self.isAuthoritative = isAuthoritative
            self.bounds = coordinates.reduce(MKMapRect.null) { rect, coordinate in
                rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize()))
            }
        }
    }

    /// Road ahead pulled per prefetch. Long enough to cover a motorway stretch between towns,
    /// short enough that one Overpass query answers it.
    private let prefetchWindowMetres: Double = 15_000
    /// Spacing of the sample points the prefetch asks about. Tighter than a city block, so a turn
    /// onto a side street lands on a road the table already knows.
    private let prefetchSampleSpacingMetres: Double = 200

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Converted for display in the device's own units.
    var display: (value: Int, unit: String)? {
        guard let speedLimitKph else { return nil }
        if usesMiles {
            return (Int((Double(speedLimitKph) * 0.621371).rounded()), "mph")
        }
        return (speedLimitKph, "km/h")
    }

    private var usesMiles: Bool {
        Locale.current.measurementSystem != .metric
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        table = []
        tableValidUntilMetresRemaining = nil
        speedLimitKph = nil
        lastFetch = .distantPast
        lastCoordinate = nil
    }

    /// Overpass is a free, shared, community-run endpoint, so this is deliberately gentle with
    /// it: at most one request every 10s, and only after moving 80m — about one city block, so a
    /// turn onto a new street resolves quickly without firing on every GPS tick.
    func refreshIfNeeded(at location: CLLocation) async {
        // The prefetched table answers instantly and works with no signal, so it goes first and
        // short-circuits everything below — including the throttle, since there's nothing to be
        // gentle with.
        if let known = localLimit(at: location.coordinate) {
            speedLimitKph = known
            lastCoordinate = location.coordinate
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastFetch) >= 10 else { return }
        if let last = lastCoordinate {
            let moved = location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard moved >= 80 else { return }
        }
        lastFetch = now
        lastCoordinate = location.coordinate

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            await self?.fetch(around: location.coordinate)
        }
        await inFlight?.value
    }

    // MARK: Prefetching the road ahead

    /// Pulls the posted limits for the next stretch of a trip in one request, ahead of needing
    /// them.
    ///
    /// Called when a trip starts and again as the driver eats through what's already been pulled.
    /// `metresRemaining` is what navigation already tracks, so "have I run out of prefetched road"
    /// is a comparison rather than another geometry walk.
    func prefetch(along coordinates: [CLLocationCoordinate2D], metresRemaining: Double) {
        // Still well inside the stretch already pulled.
        if let until = tableValidUntilMetresRemaining, metresRemaining > until + 2_000 { return }
        guard prefetchTask == nil || prefetchTask?.isCancelled == true else { return }
        guard coordinates.count > 1 else { return }

        let samples = Self.sample(
            coordinates,
            everyMetres: prefetchSampleSpacingMetres,
            upToMetres: prefetchWindowMetres
        )
        guard !samples.isEmpty else { return }

        prefetchTask = Task { [weak self] in
            guard let self else { return }
            var segments = await openStreetMapSegments(around: samples)
            if samples.contains(where: Self.isWithinNYC) {
                segments += await nycSegments(covering: samples)
            }
            guard !Task.isCancelled, !segments.isEmpty else {
                prefetchTask = nil
                return
            }
            table = segments
            tableValidUntilMetresRemaining = max(0, metresRemaining - prefetchWindowMetres)
            prefetchTask = nil
        }
    }

    /// Throws away the prefetched table without clearing the sign.
    ///
    /// Used on a reroute: the table describes roads that are no longer being driven, but the
    /// number currently on screen is still the limit for the road under the car right now, and
    /// blinking it off for a second is worse than a moment of staleness.
    func invalidatePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        table = []
        tableValidUntilMetresRemaining = nil
    }

    /// The posted limit for the road the driver is on, from the prefetched table, or nil when the
    /// table has nothing near enough to be about this road.
    private func localLimit(at coordinate: CLLocationCoordinate2D) -> Int? {
        guard !table.isEmpty else { return nil }
        let point = MKMapPoint(coordinate)
        // Metres-to-map-points varies with latitude; this is the 25m tolerance below, converted
        // once and padded, so the box test can't reject a road the exact test would have matched.
        let padding = 25 / MKMetersPerMapPointAtLatitude(coordinate.latitude)
        let search = MKMapRect(
            x: point.x - padding, y: point.y - padding,
            width: padding * 2, height: padding * 2
        )

        var best: (distance: Double, authoritative: Bool, kph: Int)?
        for segment in table {
            guard segment.bounds.intersects(search) else { continue }
            let distance = Self.distance(from: coordinate, to: segment.coordinates)
            guard distance <= 25 else { continue }
            // City data wins ties outright; otherwise the nearer road is the one being driven.
            let beatsCurrent = best.map { current in
                segment.isAuthoritative && !current.authoritative
                    ? true
                    : (segment.isAuthoritative == current.authoritative && distance < current.distance)
            } ?? true
            if beatsCurrent { best = (distance, segment.isAuthoritative, segment.kph) }
        }
        return best?.kph
    }

    /// Points along a line at a fixed spacing, stopping after a given distance.
    static func sample(
        _ coordinates: [CLLocationCoordinate2D],
        everyMetres spacing: Double,
        upToMetres limit: Double
    ) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }
        var samples = [first]
        var travelled: Double = 0
        var sinceLastSample: Double = 0
        var previous = first

        for coordinate in coordinates.dropFirst() {
            let step = Self.metres(from: previous, to: coordinate)
            travelled += step
            sinceLastSample += step
            previous = coordinate
            if sinceLastSample >= spacing {
                samples.append(coordinate)
                sinceLastSample = 0
            }
            if travelled >= limit { break }
        }
        return samples
    }

    /// Every OSM way with a `maxspeed` near any of the sample points, in one union query, with
    /// geometry so each answer stays attached to the road it belongs to.
    private func openStreetMapSegments(around samples: [CLLocationCoordinate2D]) async -> [RoadSegment] {
        let clauses = samples
            .map { #"way(around:20,\#($0.latitude),\#($0.longitude))["maxspeed"];"# }
            .joined()
        let query = "[out:json][timeout:40];(\(clauses));out tags geom 800;"

        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A union over dozens of points is a bigger ask than the single-point lookups, and
        // Overpass is a shared endpoint — this waits rather than giving up early, because there's
        // nothing time-critical about it. The live lookup covers the meantime.
        request.timeoutInterval = 45
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            guard !Task.isCancelled else { return [] }
            let decoded = try JSONDecoder().decode(GeometryResponse.self, from: data)
            return decoded.elements.compactMap { element in
                guard let raw = element.tags?["maxspeed"],
                      let kph = Self.parseMaxspeed(raw),
                      let geometry = element.geometry, geometry.count > 1 else { return nil }
                return RoadSegment(
                    coordinates: geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                    kph: kph,
                    isAuthoritative: false
                )
            }
        } catch {
            return []
        }
    }

    /// NYC DOT's centrelines for the box the route runs through — the source that actually covers
    /// the residential streets OSM leaves blank.
    private func nycSegments(covering samples: [CLLocationCoordinate2D]) async -> [RoadSegment] {
        let inCity = samples.filter(Self.isWithinNYC)
        guard let first = inCity.first else { return [] }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in inCity {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        // A hair wider than the route itself, so a street the route only clips still comes back.
        let pad = 0.002

        var components = URLComponents(string: "https://data.cityofnewyork.us/resource/5mad-ntua.geojson")
        components?.queryItems = [
            URLQueryItem(
                name: "$where",
                value: "within_box(the_geom, \(maxLat + pad), \(minLon - pad), \(minLat - pad), \(maxLon + pad))"
            ),
            URLQueryItem(name: "$select", value: "postvz_sl,the_geom"),
            URLQueryItem(name: "$limit", value: "2000")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            guard !Task.isCancelled else { return [] }
            let collection = try JSONDecoder().decode(GeoJSONCollection.self, from: data)
            return collection.features.flatMap { feature -> [RoadSegment] in
                guard let mph = Int(feature.properties.postvz_sl ?? ""), mph > 0 else { return [] }
                let kph = Int((Double(mph) * 1.60934).rounded())
                return feature.geometry.lineStrings.compactMap { line in
                    guard line.count > 1 else { return nil }
                    return RoadSegment(
                        coordinates: line.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) },
                        kph: kph,
                        isAuthoritative: true
                    )
                }
            }
        } catch {
            return []
        }
    }

    // MARK: Geometry

    /// Metres from a point to a line, measured to the line rather than to its vertices.
    static func distance(from coordinate: CLLocationCoordinate2D, to line: [CLLocationCoordinate2D]) -> Double {
        guard line.count > 1 else {
            return line.first.map { Self.metres(from: coordinate, to: $0) } ?? .greatestFiniteMagnitude
        }
        let point = MKMapPoint(coordinate)
        var best = Double.greatestFiniteMagnitude
        var previous = MKMapPoint(line[0])
        for next in line.dropFirst().map(MKMapPoint.init) {
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let lengthSquared = dx * dx + dy * dy
            var t = 0.0
            if lengthSquared > 0 {
                t = ((point.x - previous.x) * dx + (point.y - previous.y) * dy) / lengthSquared
                t = min(max(t, 0), 1)
            }
            let projected = MKMapPoint(x: previous.x + dx * t, y: previous.y + dy * t)
            best = min(best, point.distance(to: projected))
            previous = next
        }
        return best
    }

    private static func metres(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        MKMapPoint(a).distance(to: MKMapPoint(b))
    }

    private struct GeometryResponse: Decodable {
        let elements: [Element]
        struct Element: Decodable {
            let tags: [String: String]?
            let geometry: [Point]?
            struct Point: Decodable {
                let lat: Double
                let lon: Double
            }
        }
    }

    /// Socrata hands back GeoJSON where each street is a LineString or a MultiLineString; both
    /// shapes are flattened to plain lists of lines here.
    private struct GeoJSONCollection: Decodable {
        let features: [Feature]

        struct Feature: Decodable {
            let properties: Properties
            let geometry: Geometry

            struct Properties: Decodable {
                let postvz_sl: String?
            }

            struct Geometry: Decodable {
                let type: String
                let coordinates: Coordinates

                var lineStrings: [[[Double]]] {
                    switch (type, coordinates) {
                    case ("LineString", .line(let line)): [line]
                    case ("MultiLineString", .multiLine(let lines)): lines
                    default: []
                    }
                }

                enum Coordinates: Decodable {
                    case line([[Double]])
                    case multiLine([[[Double]]])

                    init(from decoder: Decoder) throws {
                        let container = try decoder.singleValueContainer()
                        if let multi = try? container.decode([[[Double]]].self) {
                            self = .multiLine(multi)
                        } else {
                            self = .line(try container.decode([[Double]].self))
                        }
                    }
                }
            }
        }
    }

    /// Whether a source answered, so a network failure can leave the previous reading alone
    /// instead of blinking the sign off mid-drive, while a genuine "no data here" clears it.
    private enum Lookup {
        case found(Int)
        case noData
        case failed
    }

    private func fetch(around coordinate: CLLocationCoordinate2D) async {
        // NYC DOT is authoritative and complete inside the city — including the residential
        // streets OSM leaves untagged — and it answers far faster than Overpass, so it goes
        // first when in range. OSM is the worldwide source everywhere else.
        var results: [Lookup] = []

        if Self.isWithinNYC(coordinate) {
            let city = await nycSpeedLimit(around: coordinate)
            if case .found(let kph) = city {
                speedLimitKph = kph
                return
            }
            results.append(city)
        }

        let osm = await openStreetMapSpeedLimit(around: coordinate)
        if case .found(let kph) = osm {
            speedLimitKph = kph
            return
        }
        results.append(osm)

        // Only clear once a source actually told us there's nothing here.
        if results.contains(where: { if case .noData = $0 { return true } else { return false } }) {
            speedLimitKph = nil
        }
    }

    private func openStreetMapSpeedLimit(around coordinate: CLLocationCoordinate2D) async -> Lookup {
        // 25m radius keeps this to the road actually being driven rather than pulling in the
        // cross street at an intersection.
        let query = """
        [out:json][timeout:10];way(around:25,\(coordinate.latitude),\(coordinate.longitude))["maxspeed"];out tags 5;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            // Overpass is a busy shared endpoint and answers 429/504 under load. That's a failure
            // to consult it, not evidence the road is untagged — previously this returned early
            // and skipped the city source entirely.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed
            }
            guard !Task.isCancelled else { return .failed }
            let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)

            // Prefer the highest-classification road nearby: at an intersection the driver is far
            // more likely to be on the arterial than the side street.
            let best = decoded.elements
                .compactMap { element -> (rank: Int, kph: Int)? in
                    guard let raw = element.tags?["maxspeed"],
                          let kph = Self.parseMaxspeed(raw) else { return nil }
                    return (Self.roadRank(element.tags?["highway"]), kph)
                }
                .max { $0.rank < $1.rank }

            return best.map { .found($0.kph) } ?? .noData
        } catch {
            return .failed
        }
    }

    /// NYC DOT posts limits per street centreline segment. A 60m circle is wide enough to catch
    /// the segment when GPS puts you slightly off the centreline, narrow enough not to reach the
    /// next street over.
    private func nycSpeedLimit(around coordinate: CLLocationCoordinate2D) async -> Lookup {
        var components = URLComponents(string: "https://data.cityofnewyork.us/resource/5mad-ntua.json")
        components?.queryItems = [
            URLQueryItem(name: "$where", value: "within_circle(the_geom, \(coordinate.latitude), \(coordinate.longitude), 60)"),
            URLQueryItem(name: "$select", value: "postvz_sl"),
            URLQueryItem(name: "$limit", value: "5")
        ]
        guard let url = components?.url else { return .failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed
            }
            guard !Task.isCancelled else { return .failed }
            let rows = try JSONDecoder().decode([NYCSpeedLimitRow].self, from: data)
            // Lowest posted limit among overlapping segments is the safe one to show.
            let mph = rows.compactMap { Int($0.postvz_sl ?? "") }.filter { $0 > 0 }.min()
            guard let mph else { return .noData }
            return .found(Int((Double(mph) * 1.60934).rounded()))
        } catch {
            return .failed
        }
    }

    /// Rough bounding box covering the five boroughs.
    nonisolated private static func isWithinNYC(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (40.47...40.93).contains(coordinate.latitude) && (-74.28...(-73.68)).contains(coordinate.longitude)
    }

    private struct NYCSpeedLimitRow: Decodable {
        let postvz_sl: String?
    }

    /// OSM stores this as a free-text tag: "50" (implicitly km/h), "25 mph", "30 knots", or
    /// country presets like "US:urban" that carry no number at all. Only the forms with a real
    /// number are used; anything else is treated as unknown rather than guessed at.
    nonisolated static func parseMaxspeed(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let number = value.prefix { $0.isNumber }
        guard let magnitude = Int(number), magnitude > 0 else { return nil }
        if value.contains("mph") {
            return Int((Double(magnitude) * 1.60934).rounded())
        }
        if value.contains("knot") { return nil }
        return magnitude  // OSM's default unit is km/h.
    }

    /// Rough OSM highway-classification ordering, biggest road first.
    private static func roadRank(_ highway: String?) -> Int {
        switch highway {
        case "motorway", "motorway_link": 6
        case "trunk", "trunk_link": 5
        case "primary", "primary_link": 4
        case "secondary", "secondary_link": 3
        case "tertiary", "tertiary_link": 2
        case "residential", "unclassified", "living_street": 1
        default: 0
        }
    }

    private struct OverpassResponse: Decodable {
        let elements: [Element]
        struct Element: Decodable {
            let tags: [String: String]?
        }
    }
}
