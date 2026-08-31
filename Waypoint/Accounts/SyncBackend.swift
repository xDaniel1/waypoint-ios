import Foundation

/// Everything Waypoint would need from a server, and nothing more.
///
/// This exists now so tomorrow's backend choice is a swap rather than a rewrite. The app has never
/// had a server — favorites and recents live on the device and already ride iCloud's key-value
/// store between the user's *Apple* devices. The only thing an account actually buys is reaching
/// a phone that isn't Apple's, which is the whole reason for wanting one.
///
/// Nothing here is implemented against a real service yet. `UnconfiguredBackend` is the shipped
/// default and it fails loudly instead of pretending to sync, so no screen can ever show a
/// "Synced" state that didn't happen.
protocol SyncBackend: Sendable {
    /// Whatever the server currently holds for this account.
    func pull(for account: Account) async throws -> SyncSnapshot
    /// Replaces the server's copy with this one.
    func push(_ snapshot: SyncSnapshot, for account: Account) async throws
}

/// The user data worth carrying between devices. Deliberately just the two local stores — nothing
/// else in the app is user-authored, and route history isn't something to upload by default.
struct SyncSnapshot: Codable, Equatable {
    var favorites: [FavoritePlace]
    var recents: [RecentSearch]
    /// When this snapshot was produced, for last-writer-wins until something better is designed.
    /// Real conflict resolution is a backend decision and isn't guessed at here.
    var updatedAt: Date

    static let empty = SyncSnapshot(favorites: [], recents: [], updatedAt: .distantPast)
}

enum SyncError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Waypoint has no server yet, so there's nothing to sync with."
        }
    }
}

/// The shipped default until a real backend exists.
struct UnconfiguredBackend: SyncBackend {
    func pull(for account: Account) async throws -> SyncSnapshot { throw SyncError.notConfigured }
    func push(_ snapshot: SyncSnapshot, for account: Account) async throws { throw SyncError.notConfigured }
}
