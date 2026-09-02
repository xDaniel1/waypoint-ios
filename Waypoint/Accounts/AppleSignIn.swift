import AuthenticationServices
import Foundation

/// Turns Apple's authorization result into our `Account`.
///
/// Sign in with Apple is genuinely usable with no server: `ASAuthorizationAppleIDCredential` comes
/// back signed by Apple and carries a stable per-team user identifier. What it can't do without a
/// server is *prove* anything — the identity token has to be verified against Apple's public keys
/// somewhere we control before it means more than "this device said so". Until then this is a
/// local identity, which is exactly what `AccountStore` treats it as.
enum AppleSignIn {
    static func account(from authorization: ASAuthorization) -> Account? {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            return nil
        }
        return Account(
            id: credential.user,
            provider: .apple,
            // Apple sends name and email only on the very first authorization for an Apple ID and
            // never again — not even after signing out and back in. Storing whatever arrives, and
            // tolerating nil forever after, is the documented behaviour rather than a gap.
            displayName: credential.fullName.flatMap {
                let formatted = PersonNameComponentsFormatter().string(from: $0)
                return formatted.isEmpty ? nil : formatted
            },
            email: credential.email
        )
    }

    /// Apple can revoke or a user can remove the app from their Apple ID; this is how you find out
    /// the stored account is stale rather than trusting it forever.
    static func isStillAuthorized(_ account: Account) async -> Bool {
        guard account.provider == .apple else { return true }
        let provider = ASAuthorizationAppleIDProvider()
        let state = try? await provider.credentialState(forUserID: account.id)
        return state == .authorized
    }
}
