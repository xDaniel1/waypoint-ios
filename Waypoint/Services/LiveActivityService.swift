// ActivityKit's `Activity<Attributes>` isn't `Sendable` in this SDK yet, which trips Swift 6
// strict concurrency when handing it to `update`/`end` (both effectively run off the calling
// actor). `@preconcurrency` defers that specific check to a warning, matching how Apple's own
// system frameworks are treated until they're fully audited for Swift 6.
@preconcurrency import ActivityKit
import Foundation

/// Starts, updates, and ends the Lock Screen / Dynamic Island Live Activity for an active trip.
/// A no-op wherever Live Activities aren't supported or the user hasn't allowed them —
/// `ActivityAuthorizationInfo` reports that directly, so this never needs to prompt for
/// permission itself; there's simply no activity to show.
@MainActor
final class LiveActivityService {
    private var activity: Activity<NavigationActivityAttributes>?

    func start(
        destinationName: String,
        instruction: String,
        remainingMinutes: Int,
        remainingDistanceText: String,
        arrivalDate: Date
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = NavigationActivityAttributes(destinationName: destinationName)
        let state = NavigationActivityAttributes.ContentState(
            currentInstruction: instruction,
            remainingMinutes: remainingMinutes,
            remainingDistanceText: remainingDistanceText,
            arrivalDate: arrivalDate
        )
        activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    /// Live Activity updates are rate-limited by the system, so the caller throttles how often
    /// this is invoked (e.g. per maneuver step, not per GPS fix) rather than this doing it.
    func update(instruction: String, remainingMinutes: Int, remainingDistanceText: String, arrivalDate: Date) {
        guard let activity else { return }
        let state = NavigationActivityAttributes.ContentState(
            currentInstruction: instruction,
            remainingMinutes: remainingMinutes,
            remainingDistanceText: remainingDistanceText,
            arrivalDate: arrivalDate
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
