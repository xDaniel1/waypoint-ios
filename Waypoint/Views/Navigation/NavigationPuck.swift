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
                .font(.system(size: 11, weight: .bold))
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

/// Apple Maps' speed limit sign. Renders the US/regional variants shown during navigation.
struct SpeedLimitSign: View {
    let speedLimit: Int
    /// "mph" or "km/h" — drives which sign style is used, matching regional conventions.
    let unitLabel: String

    var body: some View {
        VStack(spacing: 0) {
            Text(unitLabel == "mph" ? "SPEED\nLIMIT" : "VELOCIDAD\nMAXIMA")
                .font(.system(size: 9, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
                .lineSpacing(-2)
            Text("\(speedLimit)")
                .font(.system(size: 30, weight: .heavy))
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
