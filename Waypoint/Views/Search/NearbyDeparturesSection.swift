import SwiftUI

/// Apple's nearby departures: the stations within walking distance and what's due at them.
///
/// Deliberately a glance, not a timetable — the question it answers is "which way do I walk",
/// and the answer is a line bullet and a number of minutes. Tapping through to a full station
/// board is a thing to build once this earns it.
struct NearbyDeparturesSection: View {
    let service: NearbyDeparturesService

    var body: some View {
        // Nothing outside the subway's reach, and nothing while the first pull is in flight —
        // an empty titled section is worse than no section.
        if !service.stations.isEmpty {
            Section {
                ForEach(service.stations) { station in
                    StationRow(station: station)
                }
            } header: {
                Text("Nearby Departures")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.leading, -4)
            }
        }
    }
}

private struct StationRow: View {
    let station: NearbyDeparturesService.Station

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Label("\(station.walkingMinutes) min", systemImage: "figure.walk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if station.departures.isEmpty {
                Text("No trains due")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Uptown and downtown are separate decisions — a rider is picking a platform,
                // not an average of both.
                ForEach(directions, id: \.isUptown) { group in
                    HStack(spacing: 8) {
                        Text(group.isUptown ? "Uptown" : "Downtown")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 68, alignment: .leading)
                        ForEach(group.departures.prefix(3)) { departure in
                            HStack(spacing: 4) {
                                LineBullet(line: departure.line)
                                Text(departure.minutesAway == 0 ? "now" : "\(departure.minutesAway)m")
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            ForEach(station.alerts.prefix(1), id: \.self) { alert in
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var directions: [(isUptown: Bool, departures: [NearbyDeparturesService.Departure])] {
        [true, false].compactMap { uptown in
            let matching = station.departures.filter { $0.isUptown == uptown }
            return matching.isEmpty ? nil : (uptown, matching)
        }
    }
}

/// The line's own roundel, in the MTA's official colour — the same thing that's on the sign.
private struct LineBullet: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(MTASubwayLines.officialColor(forLine: line) ?? .gray, in: Circle())
    }
}
