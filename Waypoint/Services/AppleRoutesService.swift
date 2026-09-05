import CoreLocation
import MapKit

/// Real MapKit-based routing — on-device `MKDirections`, free with no per-request billing, unlike
/// the Google Routes API this replaces.
///
/// `MKDirections` has no native multi-waypoint request, so a trip with stops is still computed as
/// chained point-to-point legs. What it *doesn't* do any more is throw away everything else in the
/// process: the legs are computed concurrently, each one is asked for its own alternates, and those
/// are recombined into whole-trip alternates, so adding a stop no longer collapses the route list
/// to a single take-it-or-leave-it line. Stop order is still the rider's (Apple's is too), but
/// `optimizedStopOrder` can work out a better one on request.
///
/// MapKit's public transit directions carry far less detail than Google's (no line/vehicle/stop
/// data), so transit routes here always have empty `transitSteps` rather than fabricated ones.
@MainActor
struct AppleRoutesService {
    enum RouteError: Error {
        case noRoute
    }

    /// How many whole-trip alternates to hand back. Apple shows three; more than that is noise on
    /// a card this size.
    private static let maxAlternates = 3
    /// Ceiling on the leg-alternate combinations enumerated before falling back to the cheaper
    /// greedy search. 4 legs of 3 alternates is 81 — fine; 8 legs is 6561, which is not.
    private static let maxCombinations = 128

    func computeRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: MKMapItem,
        stops: [MKMapItem] = [],
        transportType: MKDirectionsTransportType,
        avoidTolls: Bool = false,
        avoidHighways: Bool = false,
        departureDate: Date? = nil,
        arrivalDate: Date? = nil,
        avoiding blocked: [CLLocationCoordinate2D] = []
    ) async throws -> [RouteOption] {
        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        let waypoints = [originItem] + stops + [destination]

        guard waypoints.count > 2 else {
            let options = try await leg(
                from: waypoints[0], to: waypoints[1], transportType: transportType,
                avoidTolls: avoidTolls, avoidHighways: avoidHighways,
                departureDate: departureDate, arrivalDate: arrivalDate, alternates: true
            )
            return Self.preferring(options, avoiding: blocked)
        }

        // Every leg, concurrently, each with its own alternates. Sequentially this was one network
        // round trip per stop stacked end to end, and each of those already makes a second call for
        // the traffic factor — a three-stop trip spent most of its wait doing nothing.
        //
        // Child tasks rather than a task group because `MKMapItem` isn't `Sendable`: a `Task`
        // started from here inherits this main-actor isolation, so the waypoints never leave the
        // actor they were made on, while the awaits inside still overlap.
        let legTasks = (0..<(waypoints.count - 1)).map { i in
            Task {
                try await leg(
                    from: waypoints[i], to: waypoints[i + 1], transportType: transportType,
                    avoidTolls: avoidTolls, avoidHighways: avoidHighways,
                    departureDate: departureDate, arrivalDate: arrivalDate, alternates: true
                )
            }
        }
        var legs: [[RouteOption]] = []
        for task in legTasks {
            let options = try await task.value
            guard !options.isEmpty else { throw RouteError.noRoute }
            legs.append(options)
        }

        let stopNames = stops.map { $0.name ?? "Stop" }
        return Self.preferring(Self.combine(legs: legs, stopNames: stopNames), avoiding: blocked)
    }

    // MARK: Steering around what's been reported

    /// Marks which routes run through a reported problem and puts the ones that don't first.
    ///
    /// This is as close to "avoid this spot" as the routing gets, and it's worth being plain about
    /// why: `MKDirections` has no avoid-a-coordinate primitive, and neither does Google's public
    /// Routes API — that's a Navigation SDK feature. What *can* be done honestly is ask for the
    /// alternates that already exist and decline the ones that drive through the accident. When
    /// every alternate goes through it, the fastest still wins and the badge says so, because a
    /// route that quietly adds twenty minutes to dodge a cone is worse than being told.
    static func preferring(
        _ options: [RouteOption],
        avoiding blocked: [CLLocationCoordinate2D]
    ) -> [RouteOption] {
        guard !blocked.isEmpty else { return options }
        let marked = options.map { option -> RouteOption in
            var copy = option
            copy.passesReportedIncident = blocked.contains { passes(option.coordinates, within: 40, of: $0) }
            return copy
        }
        // A stable partition, so the order the alternates arrived in (fastest first) survives
        // inside each group.
        return marked.filter { !$0.passesReportedIncident } + marked.filter(\.passesReportedIncident)
    }

    /// Whether a line comes within `metres` of a point, measured to the line itself rather than to
    /// its vertices — a polyline puts several hundred metres between points on a straight, so a
    /// vertex check misses a blockage sitting squarely in the middle of one.
    static func passes(_ coordinates: [CLLocationCoordinate2D], within metres: Double, of target: CLLocationCoordinate2D) -> Bool {
        guard coordinates.count > 1 else { return false }
        let point = MKMapPoint(target)
        var previous = MKMapPoint(coordinates[0])
        for coordinate in coordinates.dropFirst() {
            let next = MKMapPoint(coordinate)
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let lengthSquared = dx * dx + dy * dy
            var t = 0.0
            if lengthSquared > 0 {
                t = ((point.x - previous.x) * dx + (point.y - previous.y) * dy) / lengthSquared
                t = min(max(t, 0), 1)
            }
            let projected = MKMapPoint(x: previous.x + dx * t, y: previous.y + dy * t)
            if point.distance(to: projected) <= metres { return true }
            previous = next
        }
        return false
    }

    // MARK: Combining legs into whole-trip alternates

    /// Builds whole-trip routes out of per-leg alternates.
    ///
    /// The old version took each leg's first route and glued them together, which meant a trip with
    /// a stop had exactly one option no matter how many genuinely different ways there were to
    /// drive it. Picking per-leg bests independently is also not the same as picking the best trip:
    /// the fastest way to the stop can dump you on the wrong side of a highway for the second half.
    private static func combine(legs: [[RouteOption]], stopNames: [String]) -> [RouteOption] {
        let picks = choices(for: legs)
        let assembled = picks.map { stitch(picking: $0, from: legs, stopNames: stopNames) }

        // Two combinations that differ only in a leg with near-identical alternates produce the
        // same trip as far as the rider is concerned; showing both wastes a card.
        var seen: [(time: TimeInterval, distance: Double)] = []
        var unique: [RouteOption] = []
        for route in assembled.sorted(by: { $0.travelTime < $1.travelTime }) {
            let isDuplicate = seen.contains {
                abs($0.time - route.travelTime) < 60 && abs($0.distance - route.distanceMeters) < 200
            }
            guard !isDuplicate else { continue }
            seen.append((route.travelTime, route.distanceMeters))
            unique.append(route)
            if unique.count == maxAlternates { break }
        }
        return unique
    }

    /// Which alternate to take for each leg, as a list of index-per-leg combinations.
    ///
    /// Enumerates the full product when it's small enough to be honest about, and otherwise keeps
    /// the fastest pick for every leg plus the variants that swap exactly one leg — enough to
    /// surface a genuinely different trip without a combinatorial explosion on a long chain.
    private static func choices(for legs: [[RouteOption]]) -> [[Int]] {
        let counts = legs.map { min($0.count, maxAlternates) }
        let total = counts.reduce(1, *)

        if total <= maxCombinations {
            var result: [[Int]] = [[]]
            for count in counts {
                result = result.flatMap { prefix in (0..<count).map { prefix + [$0] } }
            }
            return result
        }

        let fastest = legs.map { options in
            options.indices.min { options[$0].travelTime < options[$1].travelTime } ?? 0
        }
        var result = [fastest]
        for (leg, count) in counts.enumerated() where count > 1 {
            for alternate in 0..<count where alternate != fastest[leg] {
                var variant = fastest
                variant[leg] = alternate
                result.append(variant)
            }
        }
        return result
    }

    /// Glues one alternate per leg into a single trip.
    private static func stitch(
        picking indices: [Int],
        from legs: [[RouteOption]],
        stopNames: [String]
    ) -> RouteOption {
        var coordinates: [CLLocationCoordinate2D] = []
        var steps: [RouteStep] = []
        var stopIndices: [Int] = []
        var roads: [String] = []
        var totalTime: TimeInterval = 0
        var totalDistance: Double = 0
        var anyTraffic = false

        for (legNumber, options) in legs.enumerated() {
            let choice = options[min(indices[legNumber], options.count - 1)]
            totalTime += choice.travelTime
            totalDistance += choice.distanceMeters
            anyTraffic = anyTraffic || choice.hasTraffic

            // The end of one leg and the start of the next are the same place. Concatenating them
            // raw left a duplicate point at every stop, which reads as a zero-length segment to
            // navigation's map-matching and to the polyline renderer.
            var legCoordinates = choice.coordinates
            if let last = coordinates.last, let first = legCoordinates.first,
               MKMapPoint(last).distance(to: MKMapPoint(first)) < 1 {
                legCoordinates.removeFirst()
            }

            // Where this leg's arrival falls in the assembled line, so the map can pin the stop and
            // navigation can call it out on the way in.
            if legNumber < legs.count - 1 {
                let arrivalIndex = coordinates.count + max(0, legCoordinates.count - 1)
                stopIndices.append(arrivalIndex)
            }
            coordinates.append(contentsOf: legCoordinates)
            steps.append(contentsOf: choice.steps)

            // "Arrive at the dry cleaner" between legs, the way Apple breaks a multi-stop trip into
            // named arrivals rather than running the turn list straight through the stop.
            if legNumber < legs.count - 1, legNumber < stopNames.count {
                steps.append(RouteStep(
                    instruction: "Arrive at \(stopNames[legNumber])",
                    distanceMeters: 0,
                    startCoordinate: coordinates.last,
                    maneuver: "ARRIVE_STOP"
                ))
            }

            if let road = choice.roadName, !roads.contains(road) { roads.append(road) }
        }

        return RouteOption(
            coordinates: coordinates,
            travelTime: totalTime,
            distanceMeters: totalDistance,
            summary: summary(roads: roads, stopCount: legs.count - 1),
            transitSteps: [],
            steps: steps,
            hasTraffic: anyTraffic,
            stopIndices: stopIndices
        )
    }

    /// Apple names a route by the roads it's mostly made of ("via I-278 and Atlantic Ave"), not by
    /// how many stops it has — the stop count is already on screen in the endpoint list.
    private static func summary(roads: [String], stopCount: Int) -> String {
        switch roads.count {
        case 0: return stopCount == 1 ? "Route with 1 stop" : "Route with \(stopCount) stops"
        case 1: return "via \(roads[0])"
        default: return "via \(roads[0]) and \(roads[1])"
        }
    }

    // MARK: Stop order

    /// A better order to visit the same stops in, as indices into the array passed in, or nil when
    /// there's nothing to improve or the travel times couldn't be measured.
    ///
    /// The rider's own order is left alone unless they ask for this — Apple doesn't silently
    /// reshuffle a trip either, and "shortest" isn't always what someone means by the order they
    /// typed (the dry cleaner shuts at five).
    ///
    /// Times come from `calculateETA` between every pair of points, which is traffic-aware and much
    /// cheaper than asking for the full geometry of a leg that may not be used. Beyond a handful of
    /// stops the exact answer stops being worth its cost, so it switches to nearest-neighbour plus
    /// 2-opt, which lands on the optimum or next to it for trips this size.
    func optimizedStopOrder(
        from origin: CLLocationCoordinate2D,
        through stops: [MKMapItem],
        to destination: MKMapItem,
        transportType: MKDirectionsTransportType,
        avoidTolls: Bool = false,
        avoidHighways: Bool = false
    ) async throws -> [Int]? {
        guard stops.count > 1 else { return nil }

        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        let points = [originItem] + stops + [destination]
        let matrix = await Self.travelTimeMatrix(
            between: points, transportType: transportType,
            avoidTolls: avoidTolls, avoidHighways: avoidHighways
        )
        guard let matrix else { return nil }

        return Self.bestOrder(stopCount: stops.count, matrix: matrix)
    }

    /// The quickest order to visit the stops in, as indices into the caller's stop array, or nil
    /// when the order they're already in can't be meaningfully beaten.
    ///
    /// `matrix` is indexed with the origin at 0, the stops at 1…n, and the destination last.
    /// Separated from the network call above so the search itself is testable without one.
    static func bestOrder(stopCount: Int, matrix: [[TimeInterval]]) -> [Int]? {
        guard stopCount > 1, matrix.count == stopCount + 2 else { return nil }
        let stopIndices = Array(1...stopCount)
        let last = matrix.count - 1

        func cost(_ order: [Int]) -> TimeInterval {
            var total = matrix[0][order[0]]
            for i in 0..<(order.count - 1) { total += matrix[order[i]][order[i + 1]] }
            return total + matrix[order[order.count - 1]][last]
        }

        let best: [Int]
        if stopCount <= 6 {
            best = permutations(of: stopIndices).min { cost($0) < cost($1) } ?? stopIndices
        } else {
            best = twoOpt(nearestNeighbour(from: 0, over: stopIndices, matrix: matrix), cost: cost)
        }

        // Anything under a minute saved isn't worth reordering someone's trip under them.
        guard best != stopIndices, cost(stopIndices) - cost(best) > 60 else { return nil }
        return best.map { $0 - 1 }
    }

    /// Pairwise traffic-aware travel times, computed concurrently. nil if any pair is unroutable —
    /// a matrix with holes in it would optimise around a gap rather than around the road.
    private static func travelTimeMatrix(
        between points: [MKMapItem],
        transportType: MKDirectionsTransportType,
        avoidTolls: Bool,
        avoidHighways: Bool
    ) async -> [[TimeInterval]]? {
        let count = points.count
        var matrix = [[TimeInterval]](repeating: [TimeInterval](repeating: 0, count: count), count: count)

        // The last point is the destination and the first is where you already are, so no leg ever
        // starts at the destination or ends at the origin — those pairs are never asked for.
        var pairs: [(Int, Int)] = []
        for i in 0..<(count - 1) {
            for j in 1..<count where i != j { pairs.append((i, j)) }
        }

        // In small concurrent batches rather than all at once: MapKit rate-limits directions
        // requests, and six stops is nearly fifty pairs — fired together, a chunk of them come
        // back throttled, which would sink the whole matrix.
        let batchSize = 4
        for start in stride(from: 0, to: pairs.count, by: batchSize) {
            let batch = pairs[start..<min(start + batchSize, pairs.count)]
            let tasks = batch.map { pair in
                Task { () -> (Int, Int, TimeInterval?) in
                    let request = MKDirections.Request()
                    request.source = points[pair.0]
                    request.destination = points[pair.1]
                    request.transportType = transportType
                    if transportType == .automobile {
                        request.tollPreference = avoidTolls ? .avoid : .any
                        request.highwayPreference = avoidHighways ? .avoid : .any
                    }
                    let eta = try? await MKDirections(request: request).calculateETA()
                    return (pair.0, pair.1, eta?.expectedTravelTime)
                }
            }
            for task in tasks {
                let (i, j, time) = await task.value
                // One unroutable pair means optimising around a hole in the data rather than
                // around the road, so the whole reorder is abandoned instead.
                guard let time else { return nil }
                matrix[i][j] = time
            }
        }
        return matrix
    }

    private static func permutations(of items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[Int]] in
            var rest = items
            let picked = rest.remove(at: i)
            return permutations(of: rest).map { [picked] + $0 }
        }
    }

    private static func nearestNeighbour(from start: Int, over stops: [Int], matrix: [[TimeInterval]]) -> [Int] {
        var remaining = Set(stops)
        var order: [Int] = []
        var current = start
        while let next = remaining.min(by: { matrix[current][$0] < matrix[current][$1] }) {
            order.append(next)
            remaining.remove(next)
            current = next
        }
        return order
    }

    /// Repeatedly reverses the sub-path that most improves the trip, until nothing does.
    private static func twoOpt(_ order: [Int], cost: ([Int]) -> TimeInterval) -> [Int] {
        var best = order
        var bestCost = cost(best)
        var improved = true
        while improved {
            improved = false
            for i in 0..<(best.count - 1) {
                for j in (i + 1)..<best.count {
                    var candidate = best
                    candidate[i...j].reverse()
                    let candidateCost = cost(candidate)
                    if candidateCost < bestCost - 0.5 {
                        best = candidate
                        bestCost = candidateCost
                        improved = true
                    }
                }
            }
        }
        return best
    }

    // MARK: One leg

    private func leg(
        from origin: MKMapItem,
        to destination: MKMapItem,
        transportType: MKDirectionsTransportType,
        avoidTolls: Bool,
        avoidHighways: Bool,
        departureDate: Date? = nil,
        arrivalDate: Date? = nil,
        alternates: Bool
    ) async throws -> [RouteOption] {
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = transportType
        request.requestsAlternateRoutes = alternates
        request.departureDate = departureDate
        request.arrivalDate = arrivalDate
        if transportType == .automobile {
            request.tollPreference = avoidTolls ? .avoid : .any
            request.highwayPreference = avoidHighways ? .avoid : .any
        }

        let response = try await MKDirections(request: request).calculate()

        // `MKRoute.expectedTravelTime` is explicitly documented as travel time under *ideal*
        // conditions — it ignores traffic entirely, so ETAs built on it run optimistic. Only
        // `calculateETA()` returns a traffic-aware figure, so ask for it once for this leg and
        // use it to scale the per-route times (the ETA call has no notion of which alternate you
        // meant, so it corresponds to the primary route).
        let trafficFactor = await Self.trafficFactor(for: request, primary: response.routes.first)

        return response.routes.map { route in
            RouteOption(
                coordinates: route.coordinates,
                travelTime: route.expectedTravelTime * trafficFactor,
                distanceMeters: route.distance,
                summary: route.name.isEmpty ? "Route" : "via \(route.name)",
                transitSteps: [],
                steps: Self.steps(of: route),
                // Only claim traffic when it's actually slowing things down enough to notice;
                // this drives the orange duration + car-with-exclamation badge on the card.
                hasTraffic: trafficFactor > 1.15,
                roadName: route.name.isEmpty ? nil : route.name
            )
        }
    }

    // MARK: Steps

    /// A route's steps, with each maneuver's *kind* worked out from the geometry.
    ///
    /// MapKit hands back no maneuver type at all — only an instruction string — so every step used
    /// to fall through to the generic straight-up arrow, and the banner showed the same icon for a
    /// hard left as for staying on the road. Reading the instruction text would work in English and
    /// quietly stop working in every other language the app is used in.
    ///
    /// The turn is in the line itself: the bearing the road runs in coming into the maneuver
    /// against the bearing it runs in leaving it. That's the same answer in every locale.
    ///
    /// Which junction to measure at is the part that isn't obvious, and getting it wrong put a
    /// right-turn arrow next to the words "Turn left onto Dean St" on a real drive. A step's
    /// polyline is the stretch of road leading *up to* its instruction, not away from it — the
    /// maneuver `steps[i].instructions` describes happens where `steps[i].polyline` ends, and the
    /// next step's line is what you're on after making it. Checked against live MapKit routes:
    /// matching each instruction to the angle at the end of its own step agrees with the wording
    /// every time, and matching it to the angle at the start disagrees wherever two turns run
    /// back to back.
    private static func steps(of route: MKRoute) -> [RouteStep] {
        let geometries = route.steps.map { $0.polyline.coordinateList }
        let steps = route.steps.enumerated().map { index, step in
            RouteStep(
                instruction: step.instructions,
                distanceMeters: step.distance,
                startCoordinate: step.polyline.firstCoordinate,
                // The final step is the arrival; there's no road after it to turn onto.
                maneuver: index + 1 < geometries.count
                    ? maneuver(approaching: geometries[index], leaving: geometries[index + 1])
                    : nil
            )
        }
        // MapKit opens every route with a placeholder for where you're standing: no distance, no
        // instruction. Carrying it meant the first real step sat at index 1, and the navigation UI
        // worked around that by reading one step *ahead* of the one it was counting down to —
        // which is why the banner could name the turn after the turn. Dropping it here lets every
        // reader use "the step you're on" and mean it.
        guard let first = steps.first,
              first.instruction.trimmingCharacters(in: .whitespaces).isEmpty,
              first.distanceMeters < 1 else { return steps }
        return Array(steps.dropFirst())
    }

    /// Classifies a maneuver from the angle between the road in and the road out.
    ///
    /// Bearings are taken over a stretch either side of the corner rather than off the two points
    /// nearest it: polylines carry extra vertices *through* a turn, so the last pair before the
    /// corner is often already mid-turn and reads as barely a bend.
    static func maneuver(
        approaching incoming: [CLLocationCoordinate2D],
        leaving outgoing: [CLLocationCoordinate2D]
    ) -> String? {
        guard let inBearing = trailingBearing(of: incoming),
              let outBearing = leadingBearing(of: outgoing) else { return nil }

        var delta = outBearing - inBearing
        while delta > 180 { delta -= 360 }
        while delta <= -180 { delta += 360 }

        let isRight = delta > 0
        switch abs(delta) {
        // Roads bend. Under this the driver isn't doing anything they'd call a turn, and Apple
        // shows the straight arrow for it too.
        case ..<15: return nil
        case ..<40: return isRight ? "TURN_SLIGHT_RIGHT" : "TURN_SLIGHT_LEFT"
        case ..<125: return isRight ? "TURN_RIGHT" : "TURN_LEFT"
        case ..<160: return isRight ? "TURN_SHARP_RIGHT" : "TURN_SHARP_LEFT"
        default: return isRight ? "UTURN_RIGHT" : "UTURN_LEFT"
        }
    }

    /// Bearing of the last ~30m of a line — the direction you're actually travelling as you reach
    /// the corner.
    private static func leadingBearing(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDirection? {
        bearing(from: coordinates, reversed: false)
    }

    private static func trailingBearing(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDirection? {
        bearing(from: coordinates.reversed(), reversed: true)
    }

    private static func bearing(from coordinates: [CLLocationCoordinate2D], reversed: Bool) -> CLLocationDirection? {
        guard coordinates.count > 1, let anchor = coordinates.first else { return nil }
        let anchorPoint = MKMapPoint(anchor)
        // Walk out from the anchor until far enough along to have left the corner, falling back to
        // the far end for a step shorter than that.
        var far = coordinates[coordinates.count - 1]
        for coordinate in coordinates.dropFirst() {
            far = coordinate
            if anchorPoint.distance(to: MKMapPoint(coordinate)) >= 30 { break }
        }
        return reversed ? Self.bearing(from: far, to: anchor) : Self.bearing(from: anchor, to: far)
    }

    /// Compass bearing between two coordinates.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Ratio of the traffic-aware ETA to the ideal-conditions time for the same leg, so alternates
    /// can be adjusted by the same real-world factor. Falls back to 1 (no adjustment) if the ETA
    /// request fails or returns something implausible, rather than distorting every route.
    private static func trafficFactor(for request: MKDirections.Request, primary: MKRoute?) async -> Double {
        guard let primary, primary.expectedTravelTime > 0 else { return 1 }

        // calculateETA needs its own request object: a single MKDirections can only run one
        // request at a time, and the routes call above already consumed this one.
        let etaRequest = MKDirections.Request()
        etaRequest.source = request.source
        etaRequest.destination = request.destination
        etaRequest.transportType = request.transportType
        etaRequest.tollPreference = request.tollPreference
        etaRequest.highwayPreference = request.highwayPreference

        guard let eta = try? await MKDirections(request: etaRequest).calculateETA() else { return 1 }
        let factor = eta.expectedTravelTime / primary.expectedTravelTime
        // Guard against nonsense (a wildly different route matched, or a bad response) — anything
        // outside "no faster than ideal, no worse than 3x" is treated as untrustworthy.
        guard factor.isFinite, factor >= 1, factor <= 3 else { return 1 }
        return factor
    }
}

extension MKPolyline {
    /// First point of the line, or nil for an empty one — MapKit hands back a raw pointer here,
    /// so the bounds check matters.
    var firstCoordinate: CLLocationCoordinate2D? {
        guard pointCount > 0 else { return nil }
        return points()[0].coordinate
    }

    var coordinateList: [CLLocationCoordinate2D] {
        guard pointCount > 0 else { return [] }
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
