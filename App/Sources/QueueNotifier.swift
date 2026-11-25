import AppKit
import Foundation
import UserNotifications

/// Posts the "queue finished" notification. Unsigned and ad-hoc builds may not be allowed to post; every failure is
/// silent and changes nothing else.
@MainActor
final class QueueNotifier {
    private var hasRequestedAuthorization = false

    /// Asks once per launch, on the first enqueue; the system remembers the answer.
    func requestAuthorizationOnce() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Posts only while another app is frontmost; in front, the Activity lists already show the result.
    func postUnlessFrontmost(title: String, body: String) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
