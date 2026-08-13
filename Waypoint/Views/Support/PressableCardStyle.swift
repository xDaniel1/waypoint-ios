import SwiftUI

/// Press feedback for the large photo cards (Trending, Guides, City Guides) and the tinted
/// action chips.
///
/// These were all `.buttonStyle(.plain)`, which renders no press state at all — a tap on a
/// guide card looked identical to not touching it until the sheet finished presenting, which
/// reads as lag. Apple's cards dip and dim slightly the instant they're touched, which is what
/// makes the response feel immediate even when the content behind it takes a moment.
struct PressableCardStyle: ButtonStyle {
    /// Large photo cards can take a deeper dip than small chips without looking rubbery.
    var scale: CGFloat = 0.97
    var dim: Double = 0.12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .overlay {
                // Dimming via an overlay rather than `.opacity` so the card doesn't go
                // translucent and let the map show through mid-press.
                Color.black
                    .opacity(configuration.isPressed ? dim : 0)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            // Snappy on the way down, softer on release — matches how UIKit's own cells feel.
            .animation(
                configuration.isPressed ? .snappy(duration: 0.12) : .smooth(duration: 0.28),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == PressableCardStyle {
    /// For the large photo cards.
    static var pressableCard: PressableCardStyle { PressableCardStyle() }
    /// Shallower, for rows and small chips where a big dip would look excessive.
    static var pressableRow: PressableCardStyle { PressableCardStyle(scale: 0.985, dim: 0.08) }
}
