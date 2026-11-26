import AppKit
import Foundation
import UserNotifications

/// The "Queue finished" notification's identifiers. Its action and a click both show the Queue.
enum QueueNotice {
    static let category = "queue.finished"
    static let showQueueAction = "queue.show"
    static let showQueueTitle = "Show Queue"
    /// Groups the app's queue notifications together in Notification Centre.
    static let thread = "queue"
}

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

    /// Posts now. With a `category`, the notification offers that category's actions; `userInfo` comes back with
    /// the response. A notification without one is the queue's own and offers Show Queue.
    func post(title: String, body: String, category: String? = nil, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category ?? QueueNotice.category
        if category == nil { content.threadIdentifier = QueueNotice.thread }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
