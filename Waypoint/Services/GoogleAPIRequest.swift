import Foundation

/// Every Google Maps Platform key this app uses is restricted (Cloud Console) to this app's iOS
/// bundle ID. Unlike server-side key restrictions, that check is enforced by an explicit request
/// header, not inferred from which process is calling — so every Google API request, including
/// image fetches (which can't go through `AsyncImage`, since it offers no way to set headers),
/// has to set this itself or get rejected with `API_KEY_IOS_APP_BLOCKED`.
enum GoogleAPIRequest {
    static func addBundleIdentifierHeader(to request: inout URLRequest) {
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
    }
}
