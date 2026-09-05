import Foundation
import OSLog

/// The MTA's GTFS-Realtime endpoints, and the bits of the protobuf this app reads out of them.
///
/// Split out because two features now want the same feeds for different questions: a planned
/// ride asks "when does the next train that reaches my stop leave", nearby departures asks "what
/// calls at this station at all". Same download, same wire format, different filter — so the
/// feed map and the parse live here rather than being written twice.
///
/// GTFS-RT is protobuf, and pulling in a protobuf runtime for three message types would be a
/// large dependency for a small need, so `ProtobufReader` walks the wire format directly. Field
/// numbers below are from the GTFS-Realtime spec.
enum MTAFeed {

    /// A single call at a station, as the feed reports it.
    struct StopDeparture: Equatable {
        let routeID: String
        /// Station-level, with the platform's direction suffix already removed.
        let stationID: String
        /// Platform ids end in N or S. That's the only direction information in the feed, and
        /// happily it's also the one printed on the platform signs.
        let isUptown: Bool
        let time: Date
    }

    /// One feed per line group, the way the MTA splits them.
    static func url(forRoute routeID: String) -> URL? {
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

    /// Every future call at any of `stationIDs` in this feed.
    static func departures(from url: URL, atStations stationIDs: Set<String>) async -> [StopDeparture] {
        guard let data = try? await URLSession.shared.data(from: url).0 else {
            Logger.navigation.error("MTA realtime feed unreachable: \(url.lastPathComponent)")
            return []
        }
        return parseDepartures(data, stationIDs: stationIDs, now: Date())
    }

    /// Split from the download so the wire-format walk can be tested against a recorded feed.
    static func parseDepartures(_ data: Data, stationIDs: Set<String>, now: Date) -> [StopDeparture] {
        var found: [StopDeparture] = []
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
                var calls: [(station: String, isUptown: Bool, time: Date)] = []

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
                        guard let stopID, let departure, let suffix = stopID.last else { break }
                        let station = String(stopID.dropLast())
                        guard stationIDs.contains(station), departure > now else { break }
                        calls.append((station, suffix == "N", departure))
                    default:
                        break
                    }
                }

                guard let tripRoute else { continue }
                found.append(contentsOf: calls.map {
                    StopDeparture(routeID: tripRoute, stationID: $0.station,
                                  isUptown: $0.isUptown, time: $0.time)
                })
            }
        }
        return found
    }

    /// Current service alerts, keyed by the line they affect. One JSON call covers every route.
    static func alerts() async -> [String: String] {
        guard let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json"),
              let data = try? await URLSession.shared.data(from: url).0,
              let feed = try? JSONDecoder().decode(AlertFeed.self, from: data) else {
            return [:]
        }

        let now = Date().timeIntervalSince1970
        var byLine: [String: String] = [:]
        for entity in feed.entity ?? [] {
            guard let alert = entity.alert else { continue }
            // Alerts carry planned future windows too; only the ones in effect now are useful
            // to someone deciding which platform to walk to.
            let active = alert.active_period?.contains {
                Double($0.start ?? 0) <= now && (($0.end).map { Double($0) >= now } ?? true)
            } ?? true
            guard active else { continue }
            guard let text = alert.header_text?.translation?
                .first(where: { $0.language?.hasPrefix("en") ?? true })?.text else { continue }
            for informed in alert.informed_entity ?? [] {
                guard let route = informed.route_id else { continue }
                if byLine[route] == nil { byLine[route] = text }
            }
        }
        return byLine
    }

    private struct AlertFeed: Decodable {
        let entity: [Entity]?

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
