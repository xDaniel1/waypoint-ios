import SwiftUI

/// Full-screen / detailed transit step-by-step navigation sheet matching Apple Maps
/// (Screenshot 2026-08-03 at 11.18.25 PM-2.png).
struct TransitNavigationDetailSheet: View {
    let destinationName: String
    let destinationAddress: String?
    let route: RouteOption
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Pinned Header: Destination Title + Close Button
            HStack {
                Text(destinationName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(.thickMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let firstTransit = route.transitSteps.first {
                        // 1. Walk to First Transit Stop
                        walkStepView(
                            title: "Walk to \(firstTransit.departureStop) stop",
                            subtitle: leadingWalkSubtitle
                        )

                        Divider().padding(.leading, 48)

                        // 2. Board Transit Line
                        boardStepView(step: firstTransit)

                        Divider().padding(.leading, 48)

                        // 3. Exit Transit & Station Timeline
                        exitStepView(step: firstTransit)

                        Divider().padding(.leading, 48)

                        // 4. Walk to Final Destination
                        walkStepView(
                            title: "Walk to destination",
                            subtitle: trailingWalkSubtitle
                        )

                        Divider().padding(.leading, 48)

                        // 5. Arrival Step
                        arriveStepView()
                    } else {
                        ForEach(Array(route.steps.enumerated()), id: \.element.id) { index, step in
                            genericStepView(step: step)
                            if index < route.steps.count - 1 {
                                Divider().padding(.leading, 48)
                            }
                        }
                        
                        if route.steps.isEmpty {
                            walkStepView(
                                title: "Walk to \(destinationName)",
                                subtitle: "\(route.formattedDistance), about \(route.shortDuration)"
                            )
                        }

                        Divider().padding(.leading, 48)
                        arriveStepView()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Real walk-leg durations

    /// The walk minutes Google actually returned for the leg before the first transit ride, if
    /// any — never a fabricated distance/time, since Google's transit legs only carry duration.
    private var leadingWalkSubtitle: String? {
        for leg in route.transitLegs {
            if case .walk(let minutes) = leg { return "About \(minutes) min" }
            if case .transit = leg { break }
        }
        return nil
    }

    private var trailingWalkSubtitle: String? {
        for leg in route.transitLegs.reversed() {
            if case .walk(let minutes) = leg { return "About \(minutes) min" }
            if case .transit = leg { break }
        }
        return nil
    }

    // MARK: - Step Views

    private func walkStepView(title: String, subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "figure.walk")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func boardStepView(step: TransitStep) -> some View {
        HStack(alignment: .top, spacing: 16) {
            LineBadge(step: step)
                .frame(width: 32, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                Text("Board the \(step.lineName)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                if let headsign = step.headsign {
                    Text("Toward \(headsign)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let fare = route.fare {
                    Text("\(fare) fare")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let departureText = route.departureText {
                    Text(departureText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func exitStepView(step: TransitStep) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 12) {
                Text("Exit at \(step.arrivalStop)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                // Station Timeline Card
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                        Text(step.departureStop)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let departureTime = step.formattedDepartureTime {
                            Text(departureTime)
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack(spacing: 12) {
                        VStack(spacing: 2) {
                            Circle().fill(Color.blue).frame(width: 4, height: 4)
                            Circle().fill(Color.blue).frame(width: 4, height: 4)
                            Circle().fill(Color.blue).frame(width: 4, height: 4)
                        }
                        .frame(width: 16)

                        Text(rideDescription(for: step))
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                    .padding(.vertical, 6)

                    HStack(spacing: 12) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                        Text(step.arrivalStop)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let arrivalTime = step.formattedArrivalTime {
                            Text(arrivalTime)
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// Real Google-provided stop count when available; otherwise a duration-only description
    /// rather than a fabricated stop count.
    private func rideDescription(for step: TransitStep) -> String {
        if let numStops = step.numStops {
            return "Ride \(numStops) \(numStops == 1 ? "stop" : "stops"), \(route.shortDuration)"
        }
        return "Ride about \(route.shortDuration)"
    }

    private func arriveStepView() -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.pink, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("Arrive")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                Text(destinationAddress ?? destinationName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension TransitNavigationDetailSheet {
    private func genericStepView(step: RouteStep) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: step.maneuverIcon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.instruction)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                if step.distanceMeters > 0 {
                    Text(step.formattedDistance)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
