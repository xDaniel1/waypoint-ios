import SwiftUI

/// Top-of-screen next-maneuver banner during driving navigation.
///
/// Shaped the way Apple Maps shapes it: the panel runs full width and bleeds all the way to the
/// top edge so the status bar sits *on* it, with only the bottom two corners rounded. A floating
/// card with four rounded corners and map visible above it is the Google Maps look, not Apple's.
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
            .padding(.horizontal, 20)
            .padding(.bottom, nextInstruction == nil ? 18 : 14)

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
                    UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                        .fill(Color.black.opacity(0.18))
                )
            }
        }
        // The status bar sits on the blue, so the panel has to start above the safe area and pad
        // its content back down out from under the clock.
        .padding(.top, 8)
        .background {
            // The rounded shape has to live *inside* the background so it can grow into the
            // ignored top safe area. Clipping the whole banner instead trimmed the blue back to
            // the safe-area bounds, which left the status bar sitting on the map.
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                .fill(bannerBlue)
                .ignoresSafeArea(edges: .top)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
        }
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
