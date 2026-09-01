import AuthenticationServices
import Foundation
import Observation

/// Wires an account to `FavoritesStore`/`RecentSearchesStore` and a backend, keeping them in sync.
///
/// Push is debounced off local edits via each store's `onChange`. Pull happens once, right after
/// sign-in: if the server has nothing yet for this account, this device's local data seeds it
/// instead of being wiped out by an empty pull; otherwise the server's copy replaces local data.
/// After that, sync is whole-snapshot last-writer-wins — whichever device pushed most recently is
/// what any newly-signing-in device will pull. See `SyncSnapshot`'s doc comment for why real
/// per-item merge isn't attempted.
@Observable
@MainActor
final class SyncCoordinator {
    enum Status: Equatable {
        case idle
        case syncing
        case error(String)
    }

    private(set) var status: Status = .idle

    var account: Account? { accountStore.account }
    var isSignedIn: Bool { accountStore.isSignedIn }
    var isBackendConfigured: Bool { backend.isConfigured }

    private let accountStore: AccountStore
    private let backend: SupabaseBackend
    private let favoritesStore: FavoritesStore
    private let recentsStore: RecentSearchesStore

    private var pushTask: Task<Void, Never>?
    private let pushDebounce: Duration = .seconds(2)

    init(
        favoritesStore: FavoritesStore,
        recentsStore: RecentSearchesStore,
        accountStore: AccountStore = .shared,
        backend: SupabaseBackend = .shared
    ) {
        self.favoritesStore = favoritesStore
        self.recentsStore = recentsStore
        self.accountStore = accountStore
        self.backend = backend

        favoritesStore.onChange = { [weak self] in self?.schedulePush() }
        recentsStore.onChange = { [weak self] in self?.schedulePush() }

        if accountStore.isSignedIn {
            Task { await pull() }
        }
    }

    func signIn(with authorization: ASAuthorization) async {
        guard let localAccount = AppleSignIn.account(from: authorization) else {
            status = .error("Apple didn't return a usable credential.")
            return
        }
        guard
            backend.isConfigured,
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            // No server configured yet (placeholder Secrets.xcconfig values) — still honor the
            // sign-in locally so the UI reflects it. There's just nothing to sync until real
            // Supabase credentials are in place.
            accountStore.signIn(localAccount)
            return
        }

        status = .syncing
        do {
            var account = try await backend.signInWithApple(idToken: idToken)
            // The backend only knows what Apple told *it*: an email, maybe. Name only ever comes
            // down on the very first authorization, straight from the credential.
            account.displayName = localAccount.displayName
            accountStore.signIn(account)
            await pull()
        } catch {
            // Backend rejected it or is unreachable — keep the local identity so the app isn't
            // gated on network access, just unsynced until the next successful push.
            accountStore.signIn(localAccount)
            status = .error(error.localizedDescription)
        }
    }

    func signOut() {
        pushTask?.cancel()
        accountStore.signOut()
        status = .idle
        Task { try? await backend.signOut() }
    }

    private func schedulePush() {
        guard isSignedIn, backend.isConfigured else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.pushDebounce)
            guard !Task.isCancelled else { return }
            await self.push()
        }
    }

    private func push() async {
        guard let account = accountStore.account else { return }
        status = .syncing
        let snapshot = SyncSnapshot(
            favorites: favoritesStore.favorites,
            recents: recentsStore.recents,
            updatedAt: Date()
        )
        do {
            try await backend.push(snapshot, for: account)
            status = .idle
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func pull() async {
        guard let account = accountStore.account, backend.isConfigured else { return }
        status = .syncing
        do {
            let remote = try await backend.pull(for: account)
            if remote == .empty {
                await push()
            } else {
                favoritesStore.applySynced(remote.favorites)
                recentsStore.applySynced(remote.recents)
                status = .idle
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
