import GoogleSignIn
import UIKit

/// Turns a Google sign-in result into our `Account`.
///
/// Named `GoogleAccountSignIn` rather than `GoogleSignIn` so it doesn't collide with the SDK
/// module of the same name — see `AppleSignIn` for the equivalent Apple-side mapper. Unlike Apple,
/// Google returns the profile on *every* sign-in, not just the first, so there's no "tolerate nil
/// forever" caveat here.
enum GoogleAccountSignIn {
    @MainActor
    static func signIn(presenting viewController: UIViewController) async throws -> (idToken: String, account: Account) {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
        guard let idToken = result.user.idToken?.tokenString else {
            throw SyncError.noIdentityToken
        }
        let account = Account(
            id: result.user.userID ?? result.user.profile?.email ?? UUID().uuidString,
            provider: .google,
            displayName: result.user.profile?.name,
            email: result.user.profile?.email
        )
        return (idToken, account)
    }

    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }
}
