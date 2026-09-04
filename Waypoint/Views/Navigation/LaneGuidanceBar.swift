import SwiftUI

/// The strip of lane arrows Apple puts under the maneuver banner on the run-in to a junction.
///
/// Lanes that get you through the turn are drawn bright; the rest are dimmed rather than hidden,
/// because the useful information is *which* of the lanes in front of you to be in, and that only
/// reads if the ones you can see out the windscreen are all on the strip.
struct LaneGuidanceBar: View {
    let lanes: [LaneGuidanceService.Lane]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(lanes) { lane in
                laneCell(lane)
                if lane.id != lanes.last?.id {
                    // A hairline between lanes, so five arrows read as five lanes rather than one
                    // row of icons.
                    Rectangle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 1, height: 22)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(Color.black.opacity(0.55))
        }
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("laneGuidanceBar")
    }

    private func laneCell(_ lane: LaneGuidanceService.Lane) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(lane.indications.enumerated()), id: \.offset) { _, indication in
                Image(systemName: indication.symbol)
                    .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                    // The lane you want is white; the ones you don't are still legible but
                    // clearly not the answer.
                    .foregroundStyle(lane.isRecommended ? .white : Color.white.opacity(0.3))
            }
        }
        // Every lane the same width, however many arrows are painted in it. Apple draws a lane
        // that turns *and* goes straight as one composite arrow, so its lanes are all one size;
        // sizing to content instead made a four-lane road look like uneven pavement.
        .frame(width: cellWidth, height: 26)
        .background {
            if lane.isRecommended {
                Capsule().fill(.white.opacity(0.16)).padding(.horizontal, 2)
            }
        }
    }

    /// Wide enough for the busiest lane on this road, applied to all of them.
    private var cellWidth: CGFloat {
        let arrows = lanes.map(\.indications.count).max() ?? 1
        return CGFloat(arrows) * 21 + 16
    }

    private var accessibilityDescription: String {
        let recommended = lanes.filter(\.isRecommended).map { "\($0.id + 1)" }
        guard !recommended.isEmpty else { return "Lane guidance" }
        let list = ListFormatter.localizedString(byJoining: recommended)
        return recommended.count == 1
            ? "Use lane \(list) of \(lanes.count)"
            : "Use lanes \(list) of \(lanes.count)"
    }
}
