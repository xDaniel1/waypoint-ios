import Foundation
import OSLog

/// Live subway data from the MTA's GTFS-Realtime feeds: actual upcoming departures and current
/// service alerts.
///
/// Free, no API key, no per-request billing — the MTA dropped the key requirement in 2023. The
/// bundled schedule in `MTASubwayData` says when a train *should* come; this says when one
/// actually is. When the feed is unreachable (underground, most of the time you'd want it) the
/// UI falls back to the schedule rather than showing nothing.
@MainActor
@Observable
final class MTARealtimeService {
    struct Departure: Identifiable, Equatable {
        let id = UUID()
        let time: Date

        var minutesAway: Int { max(0, Int(time.timeIntervalSinceNow / 60)) }

        static func == (lhs: Departure, rhs: Departure) -> Bool { lhs.time == rhs.time }
    }

    private(set) var departures: [Departure] = []
    private(set) var alerts: [String] = []
    private(set) var isLoading = false

    /// Realtime is only meaningful for about a minute, so this is a short in-memory guard against
    /// re-fetching on every re-render rather than a real cache — the feeds are free, but they're
    /// also 20KB-1MB each and there's no reason to pull them repeatedly while a sheet is open.
    private var lastFetch: Date = .distantPast
    private var lastKey: String?

    /// One feed per line group, the way the MTA splits them.
    private static func feedURL(routeID: String) -> URL? {
        let base = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2F"
        let suffix: String
        switch routeID {
        case "A", "C", "E", "H", "FS": suffix = "gtfs-ace"
        case "B", "D", "F", "M": suffix = "gtfs-bdfm"
        case "G": suffix = "gtfs-g"
        case "J", "Z": suffix = "gtfs-jz"
        case "N", "Q", "R", "W": suffix = "gtfs-nqrw"
        case "L": suffix = "gtfs-l"
        case "SI", "SIR": suffix = "gtfs-si"
        case "1", "2", "3", "4", "5", "6", "7", "GS": suffix = "gtfs"
        // Buses have their own realtime system (SIRI, not GTFS-RT) with a different shape, so
        // bus rides keep the scheduled times rather than getting wrong live ones.
        default: return nil
        }
        return URL(string: base + suffix)
    }

    func load(line: String, boardingStop: String, exitStop: String) async {
        guard let routeID = MTASubwayData.routeID(for: line),
              let stations = MTASubwayData.stationIDs(line: line, from: boardingStop, to: exitStop),
              let url = Self.feedURL(routeID: routeID) else {
            departures = []
            alerts = []
            return
        }

        let key = "\(routeID)|\(stations.boarding)|\(stations.exit)"
        if key == lastKey, Date().timeIntervalSince(lastFetch) < 45 { return }
        lastKey = key
        lastFetch = Date()

        isLoading = true
        defer { isLoading = false }

        async let departureTimes = fetchDepartures(
            url: url, routeID: routeID, boarding: stations.boarding, exit: stations.exit
        )
        async let serviceAlerts = fetchAlerts(routeID: routeID)
        let (times, alertTexts) = await (departureTimes, serviceAlerts)

        departures = times.prefix(4).map(Departure.init)
        alerts = alertTexts
    }

    // MARK: Trip updates

    private func fetchDepartures(url: URL, routeID: String, boarding: String, exit: String) async -> [Date] {
        // 10s rather than URLSession's 60s default: a departure board that arrives a minute late
        // is a departure board nobody reads, and the scheduled times are a fine fallback.
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let data = try? await URLSession.shared.data(for: request).0 else {
            Logger.navigation.error("MTA realtime feed unreachable for \(routeID)")
            return []
        }

        var times: [Date] = []
        var feed = ProtobufReader(data)

        // FeedMessage.entity == 2
        while let field = feed.nextField() {
            guard field.number == 2, case .bytes(let entityRange) = field.value else { continue }
            var entity = feed.reader(for: entityRange)

            // FeedEntity.trip_update == 3
            while let entityField = entity.nextField() {
                guard entityField.number == 3, case .bytes(let updateRange) = entityField.value else { continue }
                var update = feed.reader(for: updateRange)

                var tripRoute: String?
                var boardingTime: Date?
                var reachesExit = false
                var seenBoarding = false

                while let updateField = update.nextField() {
                    switch updateField.number {
                    case 1: // TripDescriptor
                        guard case .bytes(let tripRange) = updateField.value else { break }
                        var trip = feed.reader(for: tripRange)
                        while let tripField = trip.nextField() {
                            // TripDescriptor.route_id == 5
                            if tripField.number == 5, case .bytes(let r) = tripField.value {
                                tripRoute = feed.string(r)
                            }
                        }
                    case 2: // StopTimeUpdate
                        guard case .bytes(let stopRange) = updateField.value else { break }
                        var stop = feed.reader(for: stopRange)
                        var stopID: String?
                        var departure: Date?
                        while let stopField = stop.nextField() {
                            switch stopField.number {
                            case 4: // stop_id, platform-level ("M19S")
                                if case .bytes(let s) = stopField.value { stopID = feed.string(s) }
                            case 2, 3: // arrival / departure -> StopTimeEvent.time == 2
                                guard case .bytes(let eventRange) = stopField.value else { break }
                                var event = feed.reader(for: eventRange)
                                while let eventField = event.nextField() {
                                    if eventField.number == 2, case .varint(let seconds) = eventField.value {
                                        departure = Date(timeIntervalSince1970: TimeInterval(seconds))
                                    }
                                }
                            default:
                                break
                            }
                        }
                        // Platform ids carry an N/S suffix; the bundled data is station-level.
                        let station = stopID.map { String($0.dropLast()) }
                        if station == boarding, let departure {
                            seenBoarding = true
                            boardingTime = departure
                        } else if seenBoarding, station == exit {
                            // The exit appears later in this same trip, so it genuinely serves
                            // this ride. Checking order like this avoids having to map GTFS
                            // direction ids onto the N/S platform suffixes.
                            reachesExit = true
                        }
                    default:
                        break
                    }
                }

                if tripRoute == routeID, reachesExit, let boardingTime, boardingTime > Date() {
                    times.append(boardingTime)
                }
            }
        }
        return times.sorted()
    }

    // MARK: Alerts

    private func fetchAlerts(routeID: String) async -> [String] {
        guard let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json"),
              let data = try? await URLSession.shared.data(from: url).0,
              let feed = try? JSONDecoder().decode(AlertFeed.self, from: data) else {
            return []
        }

        let now = Date().timeIntervalSince1970
        return feed.entity.compactMap { entity -> String? in
            guard let alert = entity.alert else { return nil }
            // Only alerts affecting this line, and only ones active right now.
            guard alert.informed_entity?.contains(where: { $0.route_id == routeID }) == true else { return nil }
            if let periods = alert.active_period, !periods.isEmpty {
                let active = periods.contains { period in
                    let started = period.start.map { Double($0) <= now } ?? true
                    let notEnded = period.end.map { Double($0) >= now } ?? true
                    return started && notEnded
                }
                guard active else { return nil }
            }
            return alert.header_text?.translation?.first(where: { $0.language == "en" })?.text
                ?? alert.header_text?.translation?.first?.text
        }
        .uniqued()
        .prefix(2)
        .map { $0 }
    }

    private struct AlertFeed: Decodable {
        let entity: [Entity]

        struct Entity: Decodable { let alert: Alert? }

        struct Alert: Decodable {
            let active_period: [Period]?
            let informed_entity: [InformedEntity]?
            let header_text: Translated?
        }

        struct Period: Decodable { let start: Int?; let end: Int? }
        struct InformedEntity: Decodable { let route_id: String? }
        struct Translated: Decodable { let translation: [Translation]? }
        struct Translation: Decodable { let text: String?; let language: String? }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
