import Foundation
import Supabase

/// Talks to Supabase: Auth for turning an Apple identity token into a session, and the
/// `sync_snapshots` table (see `supabase/schema.sql`) for the actual data.
///
/// This is the one file in the app that knows a concrete backend exists. `SyncCoordinator` depends
/// on it directly for auth, since exchanging an Apple token for a session is inherently
/// Supabase-shaped plumbing, but treats it as a `SyncBackend` for pull/push — so swapping backends
/// later means replacing this file and the auth call site, not the coordinator.
final class SupabaseBackend: SyncBackend, Sendable {
    static let shared = SupabaseBackend()

    /// `nil` until `SUPABASE_URL`/`SUPABASE_ANON_KEY` in `Secrets.xcconfig` hold real values —
    /// see `Secrets.xcconfig.example`.
    private let client: SupabaseClient?

    var isConfigured: Bool { client != nil }

    private init() {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            url.scheme == "https",
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !anonKey.isEmpty
        else {
            client = nil
            return
        }
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    // MARK: - Auth

    /// Exchanges Apple's identity token for a Supabase session. Supabase verifies the token against
    /// Apple's public keys server-side, so this app never has to hold that logic itself.
    func signInWithApple(idToken: String) async throws -> Account {
        guard let client else { throw SyncError.notConfigured }
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken)
        )
        return Account(id: session.user.id.uuidString, provider: .apple, displayName: nil, email: session.user.email)
    }

    /// Same idea as `signInWithApple(idToken:)`, for Google's identity token instead.
    func signInWithGoogle(idToken: String) async throws -> Account {
        guard let client else { throw SyncError.notConfigured }
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .google, idToken: idToken)
        )
        return Account(id: session.user.id.uuidString, provider: .google, displayName: nil, email: session.user.email)
    }

    func signOut() async throws {
        guard let client else { return }
        try await client.auth.signOut()
    }

    // MARK: - SyncBackend

    func pull(for account: Account) async throws -> SyncSnapshot {
        guard let client else { throw SyncError.notConfigured }
        let rows: [SyncRow] = try await client
            .from("sync_snapshots")
            .select()
            .eq("user_id", value: account.id)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return .empty }
        return SyncSnapshot(favorites: row.favorites, recents: row.recents, updatedAt: row.updatedAt)
    }

    func push(_ snapshot: SyncSnapshot, for account: Account) async throws {
        guard let client else { throw SyncError.notConfigured }
        let row = SyncRow(
            userID: account.id,
            favorites: snapshot.favorites,
            recents: snapshot.recents,
            updatedAt: snapshot.updatedAt
        )
        try await client
            .from("sync_snapshots")
            .upsert(row, onConflict: "user_id")
            .execute()
    }
}

private struct SyncRow: Codable {
    let userID: String
    let favorites: [FavoritePlace]
    let recents: [RecentSearch]
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case favorites
        case recents
        case updatedAt = "updated_at"
    }
}
