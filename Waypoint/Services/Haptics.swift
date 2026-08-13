import UIKit

/// Shared haptics.
///
/// The app previously created a `UIImpactFeedbackGenerator` inline at three call sites and fired
/// it immediately. That works, but the Taptic Engine has to spin up from cold each time, so the
/// tap lands a beat late — `prepare()` on a retained generator is what makes it feel
/// simultaneous with the touch. Retaining them here also keeps the feel consistent instead of
/// each screen picking its own intensity.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Call when a press becomes likely (e.g. a sheet is about to open) so the engine is warm.
    static func prepare() {
        light.prepare()
        medium.prepare()
        selection.prepare()
    }

    /// Moving between options — direction modes, map styles, tracking states.
    static func select() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// Opening a card or committing a small action.
    static func tap() {
        light.impactOccurred()
        light.prepare()
    }

    /// Weightier commitments — starting navigation, saving a favourite.
    static func commit() {
        medium.impactOccurred()
        medium.prepare()
    }

    static func success() {
        notification.notificationOccurred(.success)
    }

    static func warning() {
        notification.notificationOccurred(.warning)
    }
}
