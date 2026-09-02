import Foundation

/// Who's signed in.
///
/// Deliberately thin. This is identity only — it is *not* a session token, and nothing here is a
/// credential. Apple hands back an identity token that a backend would have to verify server-side
/// before trusting any of this, so once there's a real backend the token belongs in the Keychain
/// and not in this struct.
struct Account: Codable, Equatable, Identifiable {
    enum Provider: String, Codable {
        case apple
        case google

        var label: String {
            switch self {
            case .apple: "Apple"
            case .google: "Google"
            }
        }
    }

    /// The provider's own stable identifier for this user. Apple's is scoped to our team, so it
    /// won't match Google's for the same human — linking the two is a backend concern, not
    /// something the app can decide.
    let id: String
    let provider: Provider
    /// Both are optional and often nil. Apple only returns name and email on the *first*
    /// authorization for a given Apple ID and never again, so a signed-in account with neither is
    /// normal rather than a bug — the UI has to fall back to the provider name.
    var displayName: String?
    var email: String?

    var subtitle: String {
        email ?? "Signed in with \(provider.label)"
    }
}
