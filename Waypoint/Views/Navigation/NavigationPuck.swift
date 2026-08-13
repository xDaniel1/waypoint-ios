import SwiftUI

/// The navigation-mode location puck: a blue chevron in a white ring, with a translucent cone
/// showing which way the device is pointing — matching Apple Maps' driving puck.
struct NavigationPuck: View {
    /// Device heading in degrees. The cone points this way; the map itself may be north-up.
    let heading: Double
    /// How confident we are in the heading, in degrees. Wider cone = less certain.
    var headingAccuracy: Double = 30

    var body: some View {
        ZStack {
            HeadingCone(spread: coneSpread)
                .fill(
                    RadialGradient(
                        colors: [Color.blue.opacity(0.45), Color.blue.opacity(0.0)],
                        center: .center,
                        startRadius: 8,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(heading))
                .allowsHitTesting(false)

            Circle()
                .fill(.white)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            Circle()
                .fill(Color.blue)
                .frame(width: 24, height: 24)

            Image(systemName: "location.north.fill")
                .scaledFont(size: 11, weight: .bold, relativeTo: .caption2)
                .foregroundStyle(.white)
                .rotationEffect(.degrees(heading))
        }
        .animation(.linear(duration: 0.25), value: heading)
    }

    /// Clamp so the cone stays readable: never a needle, never a full disc.
    private var coneSpread: Double {
        min(max(headingAccuracy, 18), 70)
    }
}

/// A wedge centred on "up" (12 o'clock) before rotation is applied.
private struct HeadingCone: Shape {
    /// Half-angle of the wedge, in degrees.
    let spread: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90 - spread),
            endAngle: .degrees(-90 + spread),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// The standard (non-navigating) location dot: solid blue core, white ring, soft shadow, and a
/// translucent heading wedge — the same read as Apple Maps' blue dot.
struct UserLocationDot: View {
    /// Device heading in degrees; when nil the cone is hidden (no reliable compass fix yet).
    var heading: Double?
    var headingAccuracy: Double = 30

    var body: some View {
        ZStack {
            if let heading {
                HeadingCone(spread: min(max(headingAccuracy, 18), 70))
                    .fill(
                        RadialGradient(
                            colors: [Color.blue.opacity(0.40), Color.blue.opacity(0.0)],
                            center: .center,
                            startRadius: 6,
                            endRadius: 46
                        )
                    )
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(heading))
                    .allowsHitTesting(false)
            }

            Circle()
                .fill(.white)
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.28), radius: 3, y: 1)

            Circle()
                .fill(Color.blue)
                .frame(width: 18, height: 18)
        }
        .animation(.linear(duration: 0.25), value: heading)
    }
}

/// Apple Maps' speed limit sign. Renders the US/regional variants shown during navigation.
struct SpeedLimitSign: View {
    let speedLimit: Int
    /// "mph" or "km/h" — drives which sign style is used, matching regional conventions.
    let unitLabel: String

    var body: some View {
        VStack(spacing: 0) {
            Text(unitLabel == "mph" ? "SPEED\nLIMIT" : "VELOCIDAD\nMAXIMA")
                .scaledFont(size: 9, weight: .bold, relativeTo: .caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
                .lineSpacing(-2)
            Text("\(speedLimit)")
                .scaledFont(size: 30, weight: .heavy, relativeTo: .title)
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.black, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .accessibilityLabel("Speed limit \(speedLimit) \(unitLabel)")
    }
}

/// The driver's live speed, paired next to the posted limit sign the way Google Maps/Waze do
/// (Apple Maps doesn't show one, but the red-when-speeding alert is what people expect from
/// every other nav app). Turns red only once actually over the limit, not just close to it.
struct CurrentSpeedReadout: View {
    let speed: Int
    let unit: String
    let isOverLimit: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("\(speed)")
                .scaledFont(size: 22, weight: .heavy, relativeTo: .title2)
            Text(unit)
                .scaledFont(size: 9, weight: .semibold, relativeTo: .caption2)
        }
        .foregroundStyle(isOverLimit ? .white : .primary)
        .frame(width: 54, height: 54)
        .background(isOverLimit ? Color.red : Color(.systemBackground), in: Circle())
        .overlay(
            Circle().stroke(isOverLimit ? Color.red : Color.secondary.opacity(0.3), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.2), value: isOverLimit)
        .accessibilityLabel(isOverLimit ? "Speeding, \(speed) \(unit)" : "Current speed \(speed) \(unit)")
    }
}
