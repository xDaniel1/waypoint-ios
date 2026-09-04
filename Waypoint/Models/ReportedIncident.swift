import CoreLocation
import Foundation
import SwiftUI

/// Something a driver flagged at their location — an accident, a hazard, a closed road, a jam.
///
/// This started life as a marker that never left the phone it was made on. It now goes to
/// Waypoint's own backend when the driver is signed in, so a report made ten minutes ago by
/// someone else on the same road shows up on this map too, and the router will pick an alternate
/// that doesn't drive through it.
///
/// What it still isn't: a report to Apple or Google. Their traffic layers are fed by fleets of
/// their own and are not writable by third parties at any price, so a Waypoint report changes
/// what Waypoint users see and nothing else.
struct ReportedIncident: Identifiable {
    enum Kind: String, CaseIterable, Codable {
        case accident = "Accident"
        case hazard = "Hazard"
        case roadClosed = "Road Closed"
        case slowTraffic = "Slow Traffic"

        var symbol: String {
            switch self {
            case .accident: "car.side.rear.and.exclamationmark"
            case .hazard: "exclamationmark.triangle.fill"
            case .roadClosed: "road.lanes"
            case .slowTraffic: "clock.badge.exclamationmark.fill"
            }
        }

        /// Pin background color, matching the Apple/Waze convention of yellow for congestion
        /// vs. red for things that actually block the road.
        var tint: Color {
            switch self {
            case .accident: .red
            case .hazard: .orange
            case .roadClosed: .black
            case .slowTraffic: .yellow
            }
        }

        /// White reads fine on every tint except the yellow congestion pin, which needs a dark
        /// icon for contrast.
        var iconColor: Color {
            self == .slowTraffic ? .black : .white
        }

        /// How this gets spoken on the run-in to it.
        var spokenWarning: String {
            switch self {
            case .accident: "Accident reported ahead"
            case .hazard: "Hazard reported ahead"
            case .roadClosed: "Road closure reported ahead"
            case .slowTraffic: "Slow traffic reported ahead"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    let reportedAt: Date
    /// Reported from this device. Someone else's report is worth showing differently — you can't
    /// take back a report you didn't make, and knowing which is yours is the difference between
    /// "I said that" and "somebody said that."
    let isMine: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        coordinate: CLLocationCoordinate2D,
        reportedAt: Date = Date(),
        isMine: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.reportedAt = reportedAt
        self.isMine = isMine
    }

    /// Reports go stale fast — a lane that was blocked an hour ago usually isn't. Anything older
    /// than this is dropped rather than shown with a caveat.
    static let lifetime: TimeInterval = 2 * 60 * 60

    var isStale: Bool { Date().timeIntervalSince(reportedAt) > Self.lifetime }

    /// "8 min ago" — reports are only useful next to how old they are.
    var ageText: String {
        let minutes = Int(Date().timeIntervalSince(reportedAt) / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) hr ago"
    }
}
