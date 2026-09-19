import Foundation
import NoteLumeCore
import UserNotifications

/// Native macOS notifications for note reminders. Scheduling state is owned by
/// `ReminderCoordinator`; this class only talks to UserNotifications.
final class UNScheduler: NSObject, NotificationScheduling, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    /// Called on the main actor when the user clicks a notification.
    var onOpenNote: (@MainActor (UUID) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    @discardableResult
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingIdentifiers() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    func deliveredIdentifiers() async -> Set<String> {
        Set(await center.deliveredNotifications().map(\.request.identifier))
    }

    func schedule(_ n: ReminderNotification) async throws {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: n.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await center.add(UNNotificationRequest(identifier: n.identifier, content: content(for: n), trigger: trigger))
    }

    func deliverNow(_ n: ReminderNotification) async throws {
        try await center.add(UNNotificationRequest(identifier: n.identifier, content: content(for: n), trigger: nil))
    }

    func cancelPending(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func content(for n: ReminderNotification) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.body = n.isMissed ? "Missed reminder · " + n.body : n.body
        c.sound = .default
        c.userInfo = ["noteID": n.noteID.uuidString]
        c.threadIdentifier = "notelume.reminders"
        return c
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["noteID"] as? String, let id = UUID(uuidString: s) else { return }
        await MainActor.run { onOpenNote?(id) }
    }
}
