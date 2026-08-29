import SwiftUI

/// Thin top-of-screen strip shown while `NetworkMonitor` reports no connection.
///
/// The app is deliberately cache-heavy, so it keeps working offline for anything already
/// fetched — but a fresh search, route, or uncached photo would otherwise just spin with no
/// explanation. This says why, instead of looking broken.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
            Text("No Internet Connection")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.75), in: Capsule())
        .padding(.horizontal, 40)
    }
}
