import SwiftUI

/// A numbered pin for one of the rider's own stops on a multi-stop drive.
///
/// Apple numbers the stops on the map rather than dropping identical pins, because the whole point
/// of a stop list is the order — a map with three matching markers on it doesn't say which one
/// comes first. Sized to sit under the route line's own weight rather than compete with it.
struct RouteStopMarker: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.orange, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .accessibilityLabel("Stop \(number)")
    }
}
