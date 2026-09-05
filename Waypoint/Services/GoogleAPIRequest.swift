import Foundation

/// Every Google Maps Platform key this app uses is restricted (Cloud Console) to this app's iOS
/// bundle ID. Unlike server-side key restrictions, that check is enforced by an explicit request
/// header, not inferred from which process is calling — so every Google API request, including
/// image fetches (which can't go through `AsyncImage`, since it offers no way to set headers),
/// has to set this itself or get rejected with `API_KEY_IOS_APP_BLOCKED`.
enum GoogleAPIRequest {
    static var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
    }

    static func addBundleIdentifierHeader(to request: inout URLRequest) {
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
    }

    /// Both headers every Google call needs. The key goes here rather than in the query string
    /// because a URL travels: it lands in logs, in caches keyed by absolute string, in anything
    /// that gets handed a `URL` and decides to print it. A header stays with the one request.
    static func authorize(_ request: inout URLRequest, key: String = GoogleAPIRequest.apiKey) {
        addBundleIdentifierHeader(to: &request)
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
    }
}
