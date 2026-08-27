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
                    if let departure = formattedTime(step.departureISO) {
                        Text("Departs \(departure)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            } icon: {
                LineGlyph(step: step)
            }

            // The ride itself: boarding stop, how long it takes, exit stop. Google's Routes
            // response gives the stop *count* but not the names of the stops in between, so those
            // aren't listed rather than invented.
            VStack(alignment: .leading, spacing: 8) {
                stopRow(name: step.departureStop, isEndpoint: true)
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3, height: 22)
                        .padding(.leading, 5)
                    Text(rideSummary(for: step))
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }
                stopRow(name: step.arrivalStop, isEndpoint: true)
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

    private func stopRow(name: String, isEndpoint: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 3)
                .frame(width: 13, height: 13)
            Text(name)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
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
        Color(hex: step.color) ?? .blue
    }
}
