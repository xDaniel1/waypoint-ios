import CoreLocation
import Foundation
import Observation

/// The incident layer: what this driver has flagged, plus what other Waypoint users have flagged
/// nearby in the last couple of hours.
///
/// Why this exists at all, given the app already draws Apple's traffic overlay: that overlay is
/// *speed*, not incidents. It colours a road red because cars on it are slow, and says nothing
/// about why — a crash, a closure and a school run all look the same. Neither Apple nor Google
/// lets a third-party app read their incident feeds, let alone write to them, so the only honest
/// way to have an incident layer is to have one of your own. This is that, on the Supabase project
/// the accounts already run through.
///
/// Signed out, or with no backend configured, everything below still works — reports stay on this
/// phone and still steer the router away from the spot. They just don't reach anyone else, and the
/// UI says so rather than implying a report went somewhere it didn't.
@Observable
@MainActor
final class TrafficReportsService {
    /// Everything worth drawing right now: this device's reports and other people's, freshest
    /// first, with anything past its shelf life dropped.
    private(set) var reports: [ReportedIncident] = []
    /// Whether reports are actually reaching other people, for the report sheet's footer.
    private(set) var isSharing = false

    private let backend: SupabaseBackend
    private var lastFetch: Date = .distantPast
    private var lastFetchCentre: CLLocationCoordinate2D?
    private var inFlight: Task<Void, Never>?

    /// How far around the driver other people's reports are pulled in. Wide enough to cover the
    /// road ahead at motorway speed, narrow enough that the query stays a small one.
    private let fetchRadiusMetres: Double = 25_000

    init(backend: SupabaseBackend = .shared) {
        self.backend = backend
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        reports = []
        lastFetch = .distantPast
        lastFetchCentre = nil
    }

    /// Coordinates the router should try to steer around.
    var blockedCoordinates: [CLLocationCoordinate2D] {
        // Slow traffic is worth knowing about and worth announcing, but it isn't a reason to send
        // someone the long way round — that's what the traffic-aware ETA is already for.
        reports.filter { $0.kind != .slowTraffic }.map(\.coordinate)
    }

    /// Files a report. It lands on this map immediately whether or not the network cooperates —
    /// the driver saw the thing; making them wait on a round trip to see their own pin would be
    /// backwards.
    func report(_ kind: ReportedIncident.Kind, at coordinate: CLLocationCoordinate2D) async {
        let incident = ReportedIncident(kind: kind, coordinate: coordinate)
        reports.insert(incident, at: 0)

        guard backend.isConfigured else { return }
        do {
            try await backend.postTrafficReport(
                kind: kind.rawValue,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            isSharing = true
        } catch {
            // Signed out, offline, or the table isn't there yet: the report stays local, which is
            // exactly what it was before there was anywhere to send it.
            isSharing = false
        }
    }

    /// Pulls in nearby reports from everyone else. Gentle on purpose — once a minute, and only
    /// after moving far enough for the answer to change.
    func refreshIfNeeded(near coordinate: CLLocationCoordinate2D) async {
        pruneStale()
        guard backend.isConfigured else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFetch) >= 60 else { return }
        if let last = lastFetchCentre {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard moved >= 5_000 else { return }
        }
        lastFetch = now
        lastFetchCentre = coordinate

        inFlight?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await fetch(near: coordinate)
        }
        inFlight = task
        await task.value
    }

    private func fetch(near coordinate: CLLocationCoordinate2D) async {
        // A degree of latitude is ~111km everywhere; a degree of longitude shrinks with the
        // cosine of the latitude, which matters by the time you're this far from the equator.
        let latitudeSpan = fetchRadiusMetres / 111_000
        let longitudeSpan = fetchRadiusMetres / (111_000 * max(0.1, cos(coordinate.latitude * .pi / 180)))

        guard let rows = try? await backend.trafficReports(
            minLatitude: coordinate.latitude - latitudeSpan,
            maxLatitude: coordinate.latitude + latitudeSpan,
            minLongitude: coordinate.longitude - longitudeSpan,
            maxLongitude: coordinate.longitude + longitudeSpan,
            since: Date().addingTimeInterval(-ReportedIncident.lifetime)
        ) else {
            isSharing = false
            return
        }
        guard !Task.isCancelled else { return }
        isSharing = true

        let mine = await backend.currentUserID()
        let remote = rows.compactMap { row -> ReportedIncident? in
            guard let kind = ReportedIncident.Kind(rawValue: row.kind) else { return nil }
            return ReportedIncident(
                id: row.id,
                kind: kind,
                coordinate: CLLocationCoordinate2D(latitude: row.latitude, longitude: row.longitude),
                reportedAt: row.createdAt,
                isMine: row.userID == mine
            )
        }

        // A report made on this phone is already on this map under a locally-made id, and it comes
        // back from the server under the id Postgres gave it. Merging on id alone would draw it
        // twice, so a local report is dropped once the server has one of the same kind within a
        // block of it.
        let local = reports.filter { incident in
            incident.isMine && !remote.contains {
                $0.kind == incident.kind && Self.metres(from: $0.coordinate, to: incident.coordinate) < 60
            }
        }
        reports = (local + remote)
            .filter { !$0.isStale }
            .sorted { $0.reportedAt > $1.reportedAt }
    }

    private func pruneStale() {
        let fresh = reports.filter { !$0.isStale }
        guard fresh.count != reports.count else { return }
        reports = fresh
    }

    private static func metres(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
