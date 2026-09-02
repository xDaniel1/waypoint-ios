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
            let rawURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = Self.projectURL(from: rawURL),
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !anonKey.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            client = nil
            return
        }
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    /// Turns whatever the build settings actually produced into a project URL, or nothing.
    ///
    /// This crashed the app on launch for anyone who followed our own setup instructions. An
    /// xcconfig file treats `//` as the start of a comment, so
    /// `SUPABASE_URL = https://your-ref.supabase.co` builds as the literal string `https:` —
    /// scheme intact, host gone. The old check only asked for a scheme, so that value sailed
    /// through and went straight into supabase-swift, which answers a hostless URL with
    /// `preconditionFailure("supabaseURL must have a valid host.")`. And because this type is
    /// built eagerly (`SupabaseBackend.shared` is a default argument of `SyncCoordinator.init`,
    /// which runs while the first view is being constructed), that trap fired before the map
    /// ever drew: a mistyped config took the whole app down instead of switching sync off.
    ///
    /// So the host is taken however it arrives — bare, with a scheme, with slashes the config
    /// swallowed — and anything without one disables sync rather than being handed to the SDK.
    static func projectURL(from raw: String) -> URL? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "https:", "http:"] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
            break
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A project host is `<ref>.supabase.co` — anything without a dot, or with whitespace in
        // it, is a placeholder or a half-substituted build variable, not an address.
        guard !host.isEmpty, host.contains("."), !host.contains(" "), !host.contains("$") else {
            return nil
        }
        guard let url = URL(string: "https://\(host)"), url.host(percentEncoded: false)?.isEmpty == false else {
            return nil
        }
        return url
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
