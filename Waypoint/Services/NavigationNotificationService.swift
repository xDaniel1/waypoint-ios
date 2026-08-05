import Observation
import UIKit
import UserNotifications

/// Posts a local notification with the next turn while the app is backgrounded during active
/// navigation. This is NOT push — there's no backend server to send anything from, so remote
/// notifications aren't something this app can honestly claim. It's a local reminder so
/// backgrounding the app mid-drive doesn't leave the driver with no idea what's coming up; the
/// same text the in-app voice guidance already speaks, just also shown on the lock screen.
@Observable
@MainActor
final class NavigationNotificationService {
    private static let identifier = "com.danielguzman.waypoint.nextTurn"
    private var isAuthorized = false

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Only actually posts when backgrounded — the on-screen banner and spoken guidance already
    /// cover the foreground case, so duplicating it there would just be noise.
    func postNextTurn(_ text: String) {
        guard isAuthorized, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Waypoint"
        content.body = text
        // No sound: the in-app voice guidance already spoke this via AVSpeechSynthesizer:
        // a system notification sound on top would double up.
        content.sound = nil
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clear() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }
}
