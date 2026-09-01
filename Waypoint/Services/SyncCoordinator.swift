import AuthenticationServices
import Foundation
import Observation
import UIKit

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
        guard
            let localAccount = AppleSignIn.account(from: authorization),
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            status = .error("Apple didn't return a usable credential.")
            return
        }
        await finishSignIn(localAccount: localAccount) {
            try await self.backend.signInWithApple(idToken: idToken)
        }
    }

    func signInWithGoogle(presenting viewController: UIViewController) async {
        do {
            let (idToken, localAccount) = try await GoogleAccountSignIn.signIn(presenting: viewController)
            await finishSignIn(localAccount: localAccount) {
                try await self.backend.signInWithGoogle(idToken: idToken)
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Shared tail end of both sign-in flows: exchange the provider's token for a Supabase
    /// session if a backend is configured, falling back to a local-only identity either way — no
    /// server yet, or the server rejected/was unreachable — so sign-in never hard-fails just
    /// because sync can't happen.
    private func finishSignIn(localAccount: Account, remote: () async throws -> Account) async {
        guard backend.isConfigured else {
            accountStore.signIn(localAccount)
            return
        }
        status = .syncing
        do {
            var account = try await remote()
            // The backend only knows what the provider told *it*, which for Apple is often
            // nothing — name only ever comes down on the very first authorization, straight from
            // the credential, so the locally-mapped account is the more complete one to keep.
            account.displayName = localAccount.displayName
            accountStore.signIn(account)
            await pull()
        } catch {
            accountStore.signIn(localAccount)
            status = .error(error.localizedDescription)
        }
    }

    func signOut() {
        pushTask?.cancel()
        accountStore.signOut()
        status = .idle
        GoogleAccountSignIn.signOut()
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
