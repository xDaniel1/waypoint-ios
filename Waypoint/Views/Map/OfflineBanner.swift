import SwiftUI

/// Thin top-of-screen strip shown while `NetworkMonitor` reports no connection.
///
/// The app is deliberately cache-heavy, so it keeps working offline for anything already
/// fetched — but a fresh search, route, or uncached photo would otherwise just spin with no
/// explanation. This says why, instead of looking broken.
/// While a trip is running it says something more specific: the route in hand keeps working, and
/// what stops working is finding a new one.
struct OfflineBanner: View {
    var message = "No Internet Connection"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.75), in: Capsule())
        .padding(.horizontal, 40)
    }
}
