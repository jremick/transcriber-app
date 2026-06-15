import Foundation
import UserNotifications

/// Actionable notifications for meeting detection ("Start transcribing?")
/// and session lifecycle ("Stopped — meeting ended").
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let meetingCategory = "MEETING_DETECTED"
    nonisolated static let startAction = "START_TRANSCRIBING"
    nonisolated static let dismissAction = "DISMISS"

    var onStartRequested: ((_ appName: String?) -> Void)?

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(
            identifier: Self.startAction,
            title: "Start Transcribing",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: "Ignore")
        let category = UNNotificationCategory(
            identifier: Self.meetingCategory,
            actions: [start, dismiss],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        DebugDiag.log("notif auth status: \(settings.authorizationStatus.rawValue)")
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                DebugDiag.log("notif auth requested -> granted=\(granted)")
                return granted
            } catch {
                DebugDiag.log("notif auth error: \(error)")
                return false
            }
        default:
            return false
        }
    }

    func postMeetingDetected(appName: String, tentative: Bool) {
        let content = UNMutableNotificationContent()
        content.title = tentative
            ? "Possible meeting in \(appName)"
            : "Meeting detected in \(appName)"
        content.body = "Start transcribing?"
        content.categoryIdentifier = Self.meetingCategory
        content.userInfo = ["appName": appName]
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "meeting-\(appName)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            DebugDiag.log("meeting notif posted (\(appName)): error=\(error.map(String.init(describing:)) ?? "none")")
        }
    }

    func postInfo(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "info-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let appName = response.notification.request.content.userInfo["appName"] as? String
        guard action == Self.startAction || action == UNNotificationDefaultActionIdentifier
        else { return }
        let isMeetingCategory = response.notification.request.content.categoryIdentifier
            == Self.meetingCategory
        guard isMeetingCategory else { return }
        await MainActor.run {
            onStartRequested?(appName)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
