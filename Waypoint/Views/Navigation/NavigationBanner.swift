import SwiftUI

/// Top-of-screen next-maneuver banner during driving navigation.
///
/// A floating glass card, matching every other surface in this app.
///
/// This used to be a flat opaque navy slab bleeding edge-to-edge under the status bar with square
/// top corners — which is the Google Maps treatment, not Apple's. It now sits inset with all four
/// corners rounded on a tinted glass material, so the map shows around and through it.
struct NavigationBanner: View {
    let currentInstruction: String
    let nextInstruction: String?
    var distanceToNextStepText: String? = nil
    /// SF Symbol matching the current/next step's actual maneuver (turn left, merge, roundabout,
    /// etc.) rather than always showing a generic turn-right arrow.
    var currentManeuverIcon: String = "arrow.up"
    var nextManeuverIcon: String = "arrow.up"

    /// Apple's banner blue is deeper and less saturated than the system accent, and it goes
    /// near-navy in dark mode so it doesn't glare at night behind the windshield.
    private var bannerBlue: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.05, green: 0.20, blue: 0.44, alpha: 1)
                : UIColor(red: 0.06, green: 0.36, blue: 0.82, alpha: 1)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: currentManeuverIcon)
                    .scaledFont(size: 38, weight: .semibold, relativeTo: .largeTitle)
                    .foregroundStyle(.white)
                    .frame(width: 46)

                VStack(alignment: .leading, spacing: 1) {
                    if let distanceToNextStepText {
                        Text(distanceToNextStepText)
                            .scaledFont(size: 34, weight: .semibold, design: .rounded, relativeTo: .largeTitle)
                            .foregroundStyle(.white)
                    }
                    Text(currentInstruction)
                        .font(distanceToNextStepText == nil
                              ? .system(size: 26, weight: .semibold)
                              : .system(size: 19, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, nextInstruction == nil ? 16 : 12)

            // Apple renders the upcoming maneuver as a "Then" line on a slightly darker shelf
            // inside the same panel, not as a second full-strength banner.
            if let nextInstruction {
                HStack(spacing: 10) {
                    Text("Then")
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                    Image(systemName: nextManeuverIcon)
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                    Text(nextInstruction)
                        .scaledFont(size: 15, relativeTo: .subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26)
                        .fill(Color.black.opacity(0.16))
                )
            }
        }
        // The status bar sits on the blue, so the panel has to start above the safe area and pad
        // its content back down out from under the clock.
        .background {
            // Blue tint *under* the glass rather than a flat fill, so the material still
            // refracts the map behind it instead of reading as a painted rectangle.
            RoundedRectangle(cornerRadius: 26)
                .fill(bannerBlue.opacity(0.82))
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        .padding(.horizontal, 10)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        // Scales with the user's text size, but capped: past accessibility1 the maneuver text
        // pushes the banner far enough down the windshield view to hide the road ahead. Apple
        // constrains its driving UI the same way.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.smooth(duration: 0.3), value: currentInstruction)
        .animation(.smooth(duration: 0.3), value: nextInstruction)
        .accessibilityIdentifier("navigationBanner")
    }
}

extension String {
    /// MapKit leaves the in-progress step's `instructions` as an empty string rather than nil,
    /// which slips past `??` and renders a blank line.
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
