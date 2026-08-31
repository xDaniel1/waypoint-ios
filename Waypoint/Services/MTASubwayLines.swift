import CoreLocation
import Foundation
import MapKit
import OSLog
import SwiftUI

/// Subway line geometry for the transit map, in each line's official colour.
///
/// MapKit has no transit map style — `MKStandardMapConfiguration` only offers default/muted
/// emphasis, so Apple's transit map (coloured subway lines drawn over the streets) isn't
/// something a third-party app can switch on. The geometry is public in MTA's GTFS `shapes.txt`
/// though, so the lines are drawn from that instead, with the colours the MTA publishes: the J's
/// brown, the G's green, the L's grey.
///
/// Bundled and simplified to ~25m precision — these render at city zoom, not survey precision —
/// which keeps all 29 lines at 125KB and costs nothing to display.
@MainActor
enum MTASubwayLines {
    struct Line: Identifiable {
        let id: String
        let color: Color
        let coordinates: [CLLocationCoordinate2D]
        /// Built once at load. The map's content closure re-runs on every location fix, and
        /// handing `MapPolyline` raw coordinates there meant re-copying all 29 lines' points
        /// each time — for a rider moving through the city, several times a second.
        let polyline: MKPolyline
    }

    private struct Raw: Decodable {
        let color: String
        let points: [[Double]]
    }

    static let all: [Line] = {
        guard let url = Bundle.main.url(forResource: "MTASubwayLines", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            Logger.navigation.error("MTASubwayLines.json missing from the bundle")
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([String: Raw].self, from: data)
            return decoded.map { id, raw in
                let coordinates = raw.points.compactMap {
                    $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
                }
                return Line(
                    id: id,
                    color: Color(hex: raw.color) ?? .gray,
                    coordinates: coordinates,
                    polyline: MKPolyline(coordinates: coordinates, count: coordinates.count)
                )
            }
        } catch {
            Logger.navigation.error("Subway lines failed to decode: \(error.localizedDescription)")
            return []
        }
    }()

    /// The MTA's own published colour for a subway line's letter/number — Google's transit
    /// colour data doesn't reliably match brand colour (the J sometimes comes back generic
    /// brown-ish, sometimes not brown at all), and this bundle is already the source of truth
    /// for the colour the line draws on the map, so badges and the same line should match it.
    /// `nil` for anything that isn't one of these 29 lines — buses and other agencies fall back
    /// to whatever Google supplied.
    static func officialColor(forLine line: String) -> Color? {
        byID[line.uppercased()]
    }

    private static let byID: [String: Color] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0.color) }
    )
}
