import CoreLocation
import Foundation
import OSLog

/// Intermediate subway stops, from the MTA's own GTFS feed.
///
/// Google's Routes API gives a stop *count* for a transit ride but never the names or timings of
/// the stops in between, so the itinerary could only ever say "Ride 8 stops". Apple lists every
/// stop. The MTA publishes that data as GTFS, free and without an API key, so it's bundled here
/// rather than fetched — no per-request cost, no network dependency, and it works underground
/// where the app has no signal, which is exactly when a rider needs the stop list.
///
/// Covers the NYC subway and all five boroughs' bus routes. Other cities fall back to the plain
/// stop count.
@MainActor
enum MTASubwayData {
    struct Stop: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let lat: Double
        let lon: Double
        /// Minutes from the start of the line's full run — differences between two stops give
        /// the scheduled ride time.
        let min: Int

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private struct Pattern: Decodable {
        let headsign: String
        let stops: [Stop]
    }

    /// route id -> direction id -> the full-length run for that direction. Subway and bus are
    /// merged; route ids don't collide (subway is letters/digits, bus is "B43", "M15" and so on).
    private static let patterns: [String: [String: Pattern]] = {
        var merged: [String: [String: Pattern]] = [:]
        for resource in ["MTASubwayStops", "MTABusStops"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                Logger.navigation.error("\(resource).json missing from the bundle")
                continue
            }
            do {
                let decoded = try JSONDecoder().decode([String: [String: Pattern]].self, from: data)
                merged.merge(decoded) { existing, _ in existing }
            } catch {
                Logger.navigation.error("\(resource) failed to decode: \(error.localizedDescription)")
            }
        }
        return merged
    }()

    /// The stops between boarding and exit, exclusive of both, each with minutes from boarding.
    ///
    /// Matching is by station name because that's all Google gives us — MTA stop IDs aren't in
    /// the Routes response. Names are normalised heavily (Google says "Flushing Av", MTA says
    /// "Flushing Avenue"), and if either end can't be matched confidently this returns nil so the
    /// UI falls back to the plain stop count rather than showing a route that might be wrong.
    static func intermediateStops(
        line: String,
        from boardingStop: String,
        to exitStop: String
    ) -> [(stop: Stop, minutesFromBoarding: Int)]? {
        guard let directions = patterns[normalizedLine(line)] else { return nil }

        for pattern in directions.values {
            guard let start = index(of: boardingStop, in: pattern.stops),
                  let end = index(of: exitStop, in: pattern.stops),
                  start < end else { continue }

            let boardingOffset = pattern.stops[start].min
            return pattern.stops[(start + 1)...end].map {
                ($0, max(0, $0.min - boardingOffset))
            }
        }
        return nil
    }

    /// GTFS station ids for a ride, so realtime feeds can be matched to it. Returns nil when
    /// either end can't be resolved, same as `intermediateStops`.
    static func stationIDs(line: String, from boardingStop: String, to exitStop: String) -> (boarding: String, exit: String)? {
        guard let directions = patterns[normalizedLine(line)] else { return nil }
        for pattern in directions.values {
            guard let start = index(of: boardingStop, in: pattern.stops),
                  let end = index(of: exitStop, in: pattern.stops),
                  start < end else { continue }
            return (pattern.stops[start].id, pattern.stops[end].id)
        }
        return nil
    }

    /// The GTFS route id, normalised from whatever Google called the line.
    static func routeID(for line: String) -> String? {
        let id = normalizedLine(line)
        return patterns[id] != nil ? id : nil
    }

    private static func index(of name: String, in stops: [Stop]) -> Int? {
        let target = normalized(name)
        guard !target.isEmpty else { return nil }
        if let exact = stops.firstIndex(where: { normalized($0.name) == target }) {
            return exact
        }
        // The two sources disagree on both how much of a name to include ("Flushing Av" vs
        // "Flushing Av-Broadway") and what order to put it in (Google's "Union Sq-14 St" is the
        // MTA's "14 St-Union Sq"). Comparing token sets handles both; substring matching missed
        // the reordered ones. Only accepted when exactly one station matches.
        let targetTokens = Set(target.split(separator: " "))
        let matches = stops.indices.filter {
            let candidateTokens = Set(normalized(stops[$0].name).split(separator: " "))
            return targetTokens.isSubset(of: candidateTokens)
                || candidateTokens.isSubset(of: targetTokens)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Google returns things like "J", "J Line", "Subway J", "B43". GTFS route ids are bare
    /// letters and numbers for subway, and the route code for buses.
    private static func normalizedLine(_ line: String) -> String {
        let cleaned = line
            .replacingOccurrences(of: "Line", with: "")
            .replacingOccurrences(of: "Train", with: "")
            .replacingOccurrences(of: "Subway", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return cleaned
    }

    /// Lowercased, punctuation and common street-type abbreviations flattened, so "Flushing Av",
    /// "Flushing Ave." and "Flushing Avenue" all compare equal.
    private static func normalized(_ name: String) -> String {
        var value = name.lowercased()
        for (long, short) in [
            ("avenue", "av"), ("street", "st"), ("road", "rd"), ("boulevard", "blvd"),
            ("place", "pl"), ("square", "sq"), ("parkway", "pkwy"), ("center", "ctr"),
            ("heights", "hts"), ("junction", "jct"),
        ] {
            value = value.replacingOccurrences(of: long, with: short)
        }
        value = value.replacingOccurrences(of: "&", with: "and")
        // Punctuation becomes a space, not nothing. Deleting it fused tokens together —
        // "14 St-Union Sq" collapsed to "14 stunion sq", which could never match Google's
        // "Union Sq-14 St" no matter how the tokens were compared.
        value = String(value.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return value.split(separator: " ").joined(separator: " ")
    }
}
