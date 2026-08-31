import Foundation
import OSLog

/// Live bus arrivals from MTA Bus Time (SIRI).
///
/// Buses don't ride the GTFS-Realtime feeds the subway uses — the MTA runs them on SIRI, a
/// different protocol with a different shape, which is why wiring buses into the subway realtime
/// path would have produced wrong times rather than no times.
///
/// This one *does* need a key (free, from register.developer.obanyc.com). Without it the service
/// stays silent and bus rides keep their scheduled times, rather than showing an error for
/// something the rider can't act on.
@MainActor
@Observable
final class MTABusRealtimeService {
    struct Arrival: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        /// Stops away, when SIRI reports it — "2 stops away" is what riders actually look at.
        let stopsAway: Int?

        var minutesAway: Int { max(0, Int(time.timeIntervalSinceNow / 60)) }

        static func == (lhs: Arrival, rhs: Arrival) -> Bool {
            lhs.time == rhs.time && lhs.stopsAway == rhs.stopsAway
        }
    }

    private(set) var arrivals: [Arrival] = []

    private let apiKey = Bundle.main.object(forInfoDictionaryKey: "MTA_BUS_TIME_API_KEY") as? String ?? ""
    var isConfigured: Bool { !apiKey.isEmpty }

    private var lastFetch: Date = .distantPast
    private var lastKey: String?

    func load(line: String, boardingStopID: String) async {
        guard isConfigured else { return }

        let key = "\(line)|\(boardingStopID)"
        if key == lastKey, Date().timeIntervalSince(lastFetch) < 45 { return }
        lastKey = key
        lastFetch = Date()

        var components = URLComponents(string: "https://bustime.mta.info/api/siri/stop-monitoring.json")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "version", value: "2"),
            // Bus Time namespaces both ids by operator.
            URLQueryItem(name: "MonitoringRef", value: boardingStopID),
            URLQueryItem(name: "LineRef", value: "MTA NYCT_\(line)"),
            URLQueryItem(name: "MaximumStopVisits", value: "4"),
        ]
        guard let url = components?.url,
              let data = try? await URLSession.shared.data(from: url).0 else {
            Logger.navigation.error("Bus Time unreachable for \(line)")
            return
        }

        guard let feed = try? JSONDecoder().decode(SiriFeed.self, from: data) else {
            Logger.navigation.error("Bus Time response didn't decode for \(line)")
            return
        }

        let visits = feed.Siri.ServiceDelivery.StopMonitoringDelivery?
            .flatMap { $0.MonitoredStopVisit ?? [] } ?? []

        let formatter = Formatters.iso8601FractionalSeconds
        let plain = Formatters.iso8601

        arrivals = visits.compactMap { visit -> Arrival? in
            let journey = visit.MonitoredVehicleJourney
            let call = journey?.MonitoredCall
            guard let raw = call?.ExpectedArrivalTime ?? call?.AimedArrivalTime,
                  let date = formatter.date(from: raw) ?? plain.date(from: raw),
                  date > Date().addingTimeInterval(-60) else { return nil }
            return Arrival(time: date, stopsAway: call?.Extensions?.Distances?.StopsFromCall)
        }
        .sorted { $0.time < $1.time }
    }

    // MARK: Wire format

    private struct SiriFeed: Decodable {
        let Siri: SiriBody

        struct SiriBody: Decodable { let ServiceDelivery: Delivery }
        struct Delivery: Decodable { let StopMonitoringDelivery: [StopMonitoring]? }
        struct StopMonitoring: Decodable { let MonitoredStopVisit: [Visit]? }
        struct Visit: Decodable { let MonitoredVehicleJourney: Journey? }
        struct Journey: Decodable { let MonitoredCall: Call? }

        struct Call: Decodable {
            let ExpectedArrivalTime: String?
            let AimedArrivalTime: String?
            let Extensions: CallExtensions?
        }

        struct CallExtensions: Decodable { let Distances: Distances? }
        struct Distances: Decodable { let StopsFromCall: Int? }
    }
}
