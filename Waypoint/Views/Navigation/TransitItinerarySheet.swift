import SwiftUI

/// The step-by-step transit itinerary: walk to the station, board the line, ride N stops, exit,
/// walk to the destination, arrive.
///
/// Transit routes have no `RouteStep` turn-by-turn list, so the generic steps sheet just said
/// "Turn-by-turn steps aren't available for this route" — accurate, but useless for the mode
/// where the itinerary *is* the directions. Every value here comes from the Google transit
/// response; anything Google didn't return is omitted rather than filled in.
struct TransitItinerarySheet: View {
    let route: RouteOption
    let destinationName: String
    let onClose: () -> Void

    /// Which rides have their stop list open. Keyed by step so a multi-leg trip tracks each
    /// ride independently.
    @State private var expandedStepIDs: Set<UUID> = []
    @State private var realtime = MTARealtimeService()
    @State private var busRealtime = MTABusRealtimeService()

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(route.transitLegs.enumerated()), id: \.offset) { index, leg in
                    switch leg {
                    case .walk(let minutes):
                        walkRow(minutes: minutes, isFirst: index == 0)
                    case .transit(let step):
                        rideRows(for: step)
                    }
                }

                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Arrive")
                                .font(.headline)
                            Text(destinationName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(destinationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard let ride = route.transitSteps.first else { return }
            await realtime.load(
                line: ride.displayLine,
                boardingStop: ride.departureStop,
                exitStop: ride.arrivalStop
            )
            // Buses aren't on GTFS-RT, so when the subway feeds have nothing for this line try
            // Bus Time with the boarding stop's GTFS id.
            if realtime.departures.isEmpty,
               let ids = MTASubwayData.stationIDs(
                   line: ride.displayLine, from: ride.departureStop, to: ride.arrivalStop
               ) {
                await busRealtime.load(line: ride.displayLine, boardingStopID: "MTA_\(ids.boarding)")
            }
        }
    }

    /// Live minutes from whichever feed serves this mode — GTFS-RT for subway, SIRI for buses.
    private var liveMinutes: [Int] {
        realtime.departures.isEmpty
            ? busRealtime.arrivals.map(\.minutesAway)
            : realtime.departures.map(\.minutesAway)
    }

    /// "Departs in 6, 12 min" — the next couple of real vehicles, the way Apple phrases it.
    private var liveDepartureText: String {
        let minutes = liveMinutes
        guard let first = minutes.first else { return "" }
        let rest = minutes.dropFirst().prefix(2).map(String.init)
        let list = ([first == 0 ? "now" : String(first)] + rest).joined(separator: ", ")
        return "Departs in \(list) min"
    }

    private func walkRow(minutes: Int, isFirst: Bool) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFirst ? walkToStationTitle : "Walk to destination")
                        .font(.headline)
                    Text("About \(minutes) min")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "figure.walk")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var walkToStationTitle: String {
        guard let stop = route.transitSteps.first?.departureStop, !stop.isEmpty else {
            return "Walk to your stop"
        }
        return "Walk to \(stop)"
    }

    @ViewBuilder
    private func rideRows(for step: TransitStep) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Board the \(step.displayLine)")
                        .font(.headline)
                    if let headsign = step.headsign, !headsign.isEmpty {
                        Text(headsign)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let fare = route.fare {
                        Text("\(fare) fare")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !liveMinutes.isEmpty {
                        // Live from the MTA. The green glyph is Apple's realtime convention and
                        // only appears when the times genuinely are live.
                        HStack(spacing: 6) {
                            Text(liveDepartureText)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Image(systemName: "dot.radiowaves.up.forward")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                        }
                    } else if let departure = formattedTime(step.departureISO) {
                        Text("Departs \(departure)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }

                    if !liveMinutes.isEmpty {
                        DepartureBoard(minutes: liveMinutes, tint: lineColor(step))
                            .padding(.top, 6)
                    }

                    ForEach(realtime.alerts, id: \.self) { alert in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                            Text(alert)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }
            } icon: {
                LineGlyph(step: step)
            }

            // Boarding stop, the ride, exit stop. When the MTA feed can resolve this line the
            // intermediate stops expand inline with their scheduled timings; otherwise it stays
            // a plain count rather than inventing a stop list.
            VStack(alignment: .leading, spacing: 8) {
                stopRow(name: step.departureStop, tint: lineColor(step))

                if let stops = intermediateStops(for: step) {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            if expandedStepIDs.contains(step.id) {
                                expandedStepIDs.remove(step.id)
                            } else {
                                expandedStepIDs.insert(step.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            connector(tint: lineColor(step))
                            Text(expandedStepIDs.contains(step.id) ? "Hide stops" : rideSummary(for: step))
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)

                    if expandedStepIDs.contains(step.id) {
                        ForEach(stops, id: \.stop.id) { entry in
                            HStack(spacing: 10) {
                                connector(tint: lineColor(step), isStop: true)
                                Text(entry.stop.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Text("\(entry.minutesFromBoarding) min")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        connector(tint: lineColor(step))
                        Text(rideSummary(for: step))
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }

                stopRow(name: step.arrivalStop, tint: lineColor(step))
            }
            .padding(.vertical, 2)
        }

        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exit at \(step.arrivalStop)")
                        .font(.headline)
                    if let arrival = formattedTime(step.arrivalISO) {
                        Text("Arrives \(arrival)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "figure.walk.arrival")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
        }
    }

    private func stopRow(name: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(tint, lineWidth: 3.5)
                .frame(width: 14, height: 14)
            Text(name)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
    }

    /// The vertical line running down the ride, in the line's own colour — small hollow dots for
    /// intermediate stops, matching how Apple draws it.
    private func connector(tint: Color, isStop: Bool = false) -> some View {
        ZStack {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
            if isStop {
                Circle()
                    .strokeBorder(tint, lineWidth: 2.5)
                    .background(Circle().fill(Color(.systemBackground)))
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 14, height: isStop ? 26 : 24)
    }

    private func lineColor(_ step: TransitStep) -> Color {
        step.tintColor
    }

    private func intermediateStops(for step: TransitStep) -> [(stop: MTASubwayData.Stop, minutesFromBoarding: Int)]? {
        let stops = MTASubwayData.intermediateStops(
            line: step.displayLine,
            from: step.departureStop,
            to: step.arrivalStop
        )
        // The last entry is the exit stop, which is already drawn below the ride.
        guard let stops, stops.count > 1 else { return nil }
        return Array(stops.dropLast())
    }

    /// "Ride 8 stops, 17 min" — each half dropped when Google didn't supply it.
    private func rideSummary(for step: TransitStep) -> String {
        var parts: [String] = []
        if let stops = step.numStops, stops > 0 {
            parts.append("Ride \(stops) stop\(stops == 1 ? "" : "s")")
        }
        if let minutes = rideMinutes(for: step) {
            parts.append("\(minutes) min")
        }
        return parts.isEmpty ? "Ride" : parts.joined(separator: ", ")
    }

    private func rideMinutes(for step: TransitStep) -> Int? {
        guard let departureISO = step.departureISO, let arrivalISO = step.arrivalISO,
              let start = ISO8601DateFormatter().date(from: departureISO),
              let end = ISO8601DateFormatter().date(from: arrivalISO) else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes > 0 ? minutes : nil
    }

    private func formattedTime(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// The circular line badge — coloured with the operator's own line colour when Google gives one.
struct LineGlyph: View {
    let step: TransitStep

    var body: some View {
        Text(step.displayLine)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(lineColor, in: Circle())
    }

    private var lineColor: Color {
        step.tintColor
    }
}

/// Apple's "Upcoming Departures" strip: the next few real departures as chips, minutes on top
/// and the live indicator beneath, in the line's own colour.
struct DepartureBoard: View {
    let minutes: [Int]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Upcoming Departures")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(minutes.prefix(4).enumerated()), id: \.offset) { index, value in
                        VStack(spacing: 2) {
                            HStack(spacing: 3) {
                                Text(value == 0 ? "Now" : "\(value) min")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Image(systemName: "dot.radiowaves.up.forward")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.green)
                            }
                            Text("On time")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                // The first chip is the one you're catching, so it carries the
                                // line's colour the way Apple highlights the active departure.
                                .fill(index == 0 ? tint.opacity(0.22) : Color.secondary.opacity(0.12))
                        )
                    }
                }
            }
        }
    }
}
