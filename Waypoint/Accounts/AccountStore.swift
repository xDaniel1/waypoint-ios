import Foundation
import Observation

/// The signed-in account, persisted across launches.
///
/// Local-only on purpose, and stored in `UserDefaults` rather than the iCloud key-value store the
/// favorites use: an account is a property of *this install*, not something to broadcast to the
/// user's other devices. Signing in on the iPhone shouldn't silently sign in the iPad.
///
/// There is no token here. When a backend exists, its session token goes in the Keychain — see
/// `SyncBackend`.
@Observable
@MainActor
final class AccountStore {
    static let shared = AccountStore()

    private(set) var account: Account?

    var isSignedIn: Bool { account != nil }

    private let store: KeyValueStore
    private let key = "waypoint.account"

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
        load()
    }

    func signIn(_ account: Account) {
        self.account = account
        save()
    }

    /// Clears the local identity only. Once a backend exists this also needs to drop the session
    /// token and stop syncing — it deliberately does *not* delete favorites or recents, which are
    /// the user's data and were on this device before any account existed.
    func signOut() {
        account = nil
        save()
    }

    private func load() {
        guard let data = store.data(forKey: key) else { return }
        account = try? JSONDecoder().decode(Account.self, from: data)
    }

    private func save() {
        guard let account else {
            store.set(nil, forKey: key)
            return
        }
        store.set(try? JSONEncoder().encode(account), forKey: key)
    }
}
