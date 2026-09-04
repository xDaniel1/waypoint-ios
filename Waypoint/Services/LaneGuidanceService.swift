import CoreLocation
import Foundation
import MapKit
import Observation

/// Which lane to be in for the upcoming turn, from OpenStreetMap's `turn:lanes` tags.
///
/// Apple shows this as the arrow strip under the maneuver banner on the run-in to a junction, and
/// it's the single most useful thing on the screen at a five-lane intersection. It isn't available
/// from MapKit at any price: `MKRoute.Step` carries an instruction string, a distance and a
/// polyline, and nothing about lanes. Google's public Routes API doesn't expose it either — lane
/// guidance is a Navigation SDK feature there, which is a different (licensed) product.
///
/// So it comes from the same place the speed limits do: OSM, via the free Overpass endpoint. That
/// means real coverage on the roads where lanes are actually painted and marked up — motorway
/// approaches, big arterials — and nothing on a residential corner, which is also where nobody
/// needs it. When there's no data the strip simply doesn't appear; it never invents a lane count.
///
/// The junction *artwork* Apple draws over the top of this (the 3D sign-and-slip-road picture) is
/// licensed imagery with no public equivalent, so that part stays undone rather than approximated.
@Observable
@MainActor
final class LaneGuidanceService {
    /// The lanes across the road at the upcoming maneuver, left to right. Empty when there's
    /// nothing to show — no data for this junction, or nothing close enough to matter yet.
    private(set) var lanes: [Lane] = []

    /// One painted lane on the approach.
    struct Lane: Identifiable {
        let id: Int
        /// Everything painted in this lane, in the order OSM lists it.
        let indications: [Indication]
        /// Whether this lane leads where the route is going.
        let isRecommended: Bool
    }

    enum Indication: String {
        case left, slightLeft, sharpLeft, through, right, slightRight, sharpRight
        case reverse, mergeLeft, mergeRight, none

        /// OSM writes these with underscores and a couple of names of its own.
        init?(osm: String) {
            switch osm.trimmingCharacters(in: .whitespaces) {
            case "left": self = .left
            case "slight_left": self = .slightLeft
            case "sharp_left": self = .sharpLeft
            case "through": self = .through
            case "right": self = .right
            case "slight_right": self = .slightRight
            case "sharp_right": self = .sharpRight
            case "reverse": self = .reverse
            case "merge_to_left": self = .mergeLeft
            case "merge_to_right": self = .mergeRight
            case "none", "": self = .none
            default: return nil
            }
        }

        var symbol: String {
            switch self {
            case .left: "arrow.turn.up.left"
            case .slightLeft: "arrow.up.left"
            case .sharpLeft: "arrow.turn.left.down"
            case .through, .none: "arrow.up"
            case .right: "arrow.turn.up.right"
            case .slightRight: "arrow.up.right"
            case .sharpRight: "arrow.turn.right.down"
            case .reverse: "arrow.uturn.left"
            case .mergeLeft: "arrow.triangle.merge"
            case .mergeRight: "arrow.triangle.merge"
            }
        }

        /// The maneuvers this lane marking gets you through. A lane painted for a plain left also
        /// serves a sharp left — the paint is coarser than the turn classification is.
        var servedManeuvers: Set<String> {
            switch self {
            case .left: ["TURN_LEFT", "TURN_SHARP_LEFT", "TURN_SLIGHT_LEFT"]
            case .slightLeft: ["TURN_SLIGHT_LEFT", "TURN_LEFT"]
            case .sharpLeft: ["TURN_SHARP_LEFT", "TURN_LEFT"]
            case .right: ["TURN_RIGHT", "TURN_SHARP_RIGHT", "TURN_SLIGHT_RIGHT"]
            case .slightRight: ["TURN_SLIGHT_RIGHT", "TURN_RIGHT"]
            case .sharpRight: ["TURN_SHARP_RIGHT", "TURN_RIGHT"]
            case .reverse: ["UTURN_LEFT", "UTURN_RIGHT"]
            case .through, .none, .mergeLeft, .mergeRight: ["STRAIGHT"]
            }
        }
    }

    private let session: URLSession
    /// Which maneuver of which trip the current strip belongs to, so passing one junction clears
    /// the arrows for it rather than leaving them up over the next — and so a second trip that
    /// happens to start at the same step number doesn't inherit the first one's lanes.
    private var loaded: Key?

    private struct Key: Equatable {
        let trip: UUID
        let step: Int
    }
    private var lastRequest: Date = .distantPast
    private var inFlight: Task<Void, Never>?

    /// Far enough out to fetch and have an answer before it's needed, close enough that a motorway
    /// stretch isn't querying Overpass for a junction three minutes away.
    private let fetchWithinMetres: Double = 800
    /// Apple puts the arrows up about a quarter mile out. Earlier than this and they're on screen
    /// so long they stop meaning "now."
    private let showWithinMetres: Double = 400

    init(session: URLSession = .shared) {
        self.session = session
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        lanes = []
        loaded = nil
        lastRequest = .distantPast
    }

    /// Called on each fix during a drive. Everything it needs about the trip is passed in so this
    /// stays a lookup service rather than another thing that knows how navigation works.
    func refreshIfNeeded(
        tripID: UUID?,
        stepIndex: Int,
        maneuver: String?,
        maneuverCoordinate: CLLocationCoordinate2D?,
        approachBearing: CLLocationDirection?,
        distanceToManeuver: Double?
    ) async {
        guard let tripID, let maneuverCoordinate, let distanceToManeuver else {
            clearIfShowing()
            return
        }
        let key = Key(trip: tripID, step: stepIndex)

        // Far enough out that this junction isn't the one being driven into yet.
        guard distanceToManeuver <= fetchWithinMetres else {
            clearIfShowing()
            return
        }
        guard loaded != key else { return }
        await load(key: key, maneuver: maneuver, at: maneuverCoordinate, bearing: approachBearing)
    }

    /// Whether the arrows should actually be on screen — fetched early so the answer is ready,
    /// shown only once the junction is close enough for "which lane" to be the live question.
    func isVisible(distanceToManeuver: Double?) -> Bool {
        guard let distanceToManeuver else { return false }
        return distanceToManeuver <= showWithinMetres
    }

    private func clearIfShowing() {
        guard !lanes.isEmpty || loaded != nil else { return }
        lanes = []
        loaded = nil
    }

    private func load(
        key: Key,
        maneuver: String?,
        at coordinate: CLLocationCoordinate2D,
        bearing: CLLocationDirection?
    ) async {
        // Overpass is a free, shared, community-run endpoint; this keeps to one request every few
        // seconds the same way the speed limit lookup does.
        guard Date().timeIntervalSince(lastRequest) >= 4 else { return }
        lastRequest = Date()
        loaded = key
        // The previous junction's arrows come down the moment a new one is being looked up, rather
        // than hanging over the banner until the answer lands.
        lanes = []

        inFlight?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let found = await fetch(at: coordinate, bearing: bearing, maneuver: maneuver)
            guard !Task.isCancelled, loaded == key else { return }
            lanes = found
        }
        inFlight = task
        await task.value
    }

    private func fetch(
        at coordinate: CLLocationCoordinate2D,
        bearing: CLLocationDirection?,
        maneuver: String?
    ) async -> [Lane] {
        // Every way within 30m of the junction carrying any flavour of turn:lanes, with its
        // geometry — the geometry is what says whether it's the road being driven or the one
        // crossing it.
        let query = """
        [out:json][timeout:10];way(around:30,\(coordinate.latitude),\(coordinate.longitude))[~"^turn:lanes"~"."];out geom 12;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            guard !Task.isCancelled else { return [] }
            let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
            guard let raw = Self.approachLanes(
                in: decoded.elements, at: coordinate, travelling: bearing
            ) else { return [] }
            return Self.parse(raw, for: maneuver)
        } catch {
            return []
        }
    }

    // MARK: Picking the road you're actually on

    /// The `turn:lanes` value for the road being driven into this junction, or nil when none of
    /// the tagged ways nearby is one you're on.
    ///
    /// A junction has several tagged ways around it — the approach, the road out the far side, and
    /// the cross street, which frequently has lanes marked up too. Painting the cross street's
    /// arrows on the banner would be worse than showing nothing, so a way only counts when it runs
    /// roughly the way the car is going, and the closest one that *ends* at the junction wins,
    /// because that's the stretch with the paint on it.
    static func approachLanes(
        in elements: [OverpassResponse.Element],
        at coordinate: CLLocationCoordinate2D,
        travelling bearing: CLLocationDirection?
    ) -> String? {
        let junction = MKMapPoint(coordinate)
        var best: (score: Double, value: String)?

        for element in elements {
            guard let tags = element.tags, let geometry = element.geometry, geometry.count > 1 else { continue }
            let points = geometry.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }

            // Direction the way runs where it meets the junction.
            guard let nearest = points.indices.min(by: {
                junction.distance(to: points[$0]) < junction.distance(to: points[$1])
            }) else { continue }
            let ahead = min(nearest + 1, points.count - 1)
            let behind = max(nearest - 1, 0)
            guard ahead != behind else { continue }
            let wayBearing = AppleRoutesService.bearing(
                from: points[behind].coordinate, to: points[ahead].coordinate
            )

            let isOneWay = tags["oneway"] == "yes"
            let alignment = bearing.map { Self.angleDifference($0, wayBearing) }
            // Without a heading there's nothing to align against, so a one-way's own direction is
            // the only assumption available and a two-way is ambiguous — skipped rather than
            // guessed at, since a backwards lane strip is a wrong instruction, not a missing one.
            let runsForward: Bool
            if let alignment {
                guard alignment < 60 || alignment > 120 else { continue }  // cross street
                runsForward = alignment < 60
            } else if isOneWay {
                runsForward = true
            } else {
                continue
            }
            if isOneWay, !runsForward { continue }

            guard let value = tags[runsForward ? "turn:lanes:forward" : "turn:lanes:backward"]
                ?? (isOneWay || tags["turn:lanes:forward"] == nil ? tags["turn:lanes"] : nil),
                  !value.isEmpty else { continue }

            // How far the junction is from where this way finishes in the direction of travel.
            // The approach ends at the junction; the road out of it starts there and runs away.
            let terminal = runsForward ? points[points.count - 1] : points[0]
            let score = junction.distance(to: terminal)
            if best == nil || score < best!.score {
                best = (score, value)
            }
        }
        return best?.value
    }

    /// Smallest angle between two bearings, 0–180.
    private static func angleDifference(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }

    // MARK: Parsing

    /// Turns OSM's `left|through|through;right` into lanes, marking the ones that get you through
    /// the upcoming maneuver.
    static func parse(_ raw: String, for maneuver: String?) -> [Lane] {
        let wanted = maneuver ?? "STRAIGHT"
        let parsed = raw.components(separatedBy: "|").map { field in
            field.components(separatedBy: ";").compactMap(Indication.init(osm:))
        }
        guard !parsed.isEmpty, parsed.count <= 12 else { return [] }

        let lanes = parsed.enumerated().map { index, indications in
            let filled = indications.isEmpty ? [Indication.none] : indications
            return Lane(
                id: index,
                indications: filled,
                isRecommended: filled.contains { $0.servedManeuvers.contains(wanted) }
            )
        }
        // Nothing matching means the paint here doesn't describe this turn — showing a strip with
        // no lane highlighted asks the driver a question instead of answering one.
        return lanes.contains(where: \.isRecommended) ? lanes : []
    }

    struct OverpassResponse: Decodable {
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
}
