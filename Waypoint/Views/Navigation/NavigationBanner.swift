import SwiftUI

/// Top-of-screen next-maneuver banner during driving navigation. Matches the reference:
/// large "Start on Varet St" with a turn glyph, and a smaller next-step row underneath.
struct NavigationBanner: View {
    let currentInstruction: String
    let nextInstruction: String?
    var distanceToNextStepText: String? = nil
    /// SF Symbol matching the current/next step's actual maneuver (turn left, merge, roundabout,
    /// etc.) rather than always showing a generic turn-right arrow.
    var currentManeuverIcon: String = "arrow.up"
    var nextManeuverIcon: String = "arrow.up"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: currentManeuverIcon)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    if let distanceToNextStepText {
                        Text(distanceToNextStepText)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    Text(currentInstruction)
                        .font(distanceToNextStepText == nil ? .title2.weight(.semibold) : .subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(distanceToNextStepText == nil ? 1.0 : 0.95))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .background(Color.blue)

            if let nextInstruction {
                HStack(spacing: 14) {
                    Image(systemName: nextManeuverIcon)
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 32)
                    Text(nextInstruction)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.smooth(duration: 0.3), value: currentInstruction)
        .animation(.smooth(duration: 0.3), value: nextInstruction)
        .accessibilityIdentifier("navigationBanner")
    }
}
