import CoreLocation
import Foundation
import OSLog

/// "What's leaving near me, right now" — Apple Maps' nearby departures, without planning a trip.
///
/// Everything else transit in this app answers a question you asked ("get me from A to B").
/// This answers the one a rider standing on a corner actually has, which is "is it worth walking
/// to the L or should I take the G". Stations come from the bundled GTFS (no network, no key),
/// live times from the MTA's GTFS-RT feeds (free, no key).
///
/// Buses are deliberately absent: they run on SIRI rather than GTFS-RT, one request per stop
/// rather than one per line group, so covering every nearby bus stop would be a burst of requests
/// for a strip of the screen. Subway first; buses can follow if it earns its place.
@MainActor
@Observable
final class NearbyDeparturesService {

    struct Departure: Identifiable, Equatable {
        let id = UUID()
        let line: String
        /// "N" or "S" off the platform id — uptown/downtown in the rider's language, which is
        /// what the sign in the station says.
        let isUptown: Bool
        let time: Date

        var minutesAway: Int { max(0, Int(time.timeIntervalSinceNow / 60)) }

        static func == (lhs: Departure, rhs: Departure) -> Bool {
            lhs.line == rhs.line && lhs.isUptown == rhs.isUptown && lhs.time == rhs.time
        }
    }

    struct Station: Identifiable, Equatable {
        let id: String
        let name: String
        let metresAway: Double
        let lines: [String]
        var departures: [Departure]
        /// Service alerts affecting any line calling here.
        var alerts: [String]

        var walkingMinutes: Int { max(1, Int((metresAway / 80).rounded())) }
    }

    private(set) var stations: [Station] = []
    private(set) var isLoading = false

    /// Realtime is only good for about a minute, and the feeds are 20KB–1MB each, so this is a
    /// guard against re-pulling them on every re-render rather than a cache with any lifetime.
    private var lastFetch: Date = .distantPast
    private var lastOrigin: CLLocationCoordinate2D?

    func refreshIfNeeded(near coordinate: CLLocationCoordinate2D) async {
        if let lastOrigin {
            let moved = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: lastOrigin.latitude, longitude: lastOrigin.longitude))
            if moved < 150, Date().timeIntervalSince(lastFetch) < 60 { return }
        }

        let nearby = MTASubwayData.stations(near: coordinate)
        guard !nearby.isEmpty else {
            // Outside the subway's reach. Not an error, just nothing to say — the section hides.
            stations = []
            lastOrigin = coordinate
            lastFetch = Date()
            return
        }

        lastOrigin = coordinate
        lastFetch = Date()
        isLoading = true
        defer { isLoading = false }

        // One request per *feed*, not per line: the MTA groups lines (ACE, BDFM, NQRW…), so a
        // station served by the A, C and E costs a single fetch rather than three.
        let feeds = Set(nearby.flatMap(\.lines).compactMap(MTAFeed.url(forRoute:)))
        let stationIDs = Set(nearby.map(\.id))

        async let alertsByLine = MTAFeed.alerts()
        let calls = await withTaskGroup(of: [MTAFeed.StopDeparture].self) { group in
            for feed in feeds {
                group.addTask { await MTAFeed.departures(from: feed, atStations: stationIDs) }
            }
            var merged: [MTAFeed.StopDeparture] = []
            for await batch in group { merged.append(contentsOf: batch) }
            return merged
        }
        let alerts = await alertsByLine

        stations = nearby.map { station in
            let mine = calls
                .filter { $0.stationID == station.id }
                .sorted { $0.time < $1.time }
                .map { Departure(line: $0.routeID, isUptown: $0.isUptown, time: $0.time) }
            return Station(
                id: station.id,
                name: station.name,
                metresAway: station.metresAway,
                lines: station.lines,
                // Four is what fits without the row becoming a timetable.
                departures: Array(mine.prefix(4)),
                // Two lines at one station often share an alert; show it once.
                alerts: station.lines.compactMap { alerts[$0] }
                    .reduce(into: [String]()) { unique, text in
                        if !unique.contains(text) { unique.append(text) }
                    }
            )
        }
        // A station whose lines are all running but has no live trips due is noise on the card.
        .filter { !$0.departures.isEmpty || !$0.alerts.isEmpty }
    }
}
