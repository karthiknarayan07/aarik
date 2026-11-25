import AppKit
import QuickRunService
import UserNotifications

/// Owns the model and the updater for the app's lifetime: starts the queue at launch and lets work settle before
/// quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel.shared
    let updater = Updater()
    private var isTerminating = false
    private var volumeObservers: [any NSObjectProtocol] = []
    private var didFinishLaunching = false
    /// Files opened (Dock drop, Open With) before launch finished; delivered once it has, exactly once.
    private var pendingOpenURLs: [URL] = []

    /// Set before launch finishes, so a click on a notification that relaunched the app reaches `didReceive`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let review = UNNotificationAction(
            identifier: QuickRunNotice.reviewAction, title: QuickRunNotice.reviewActionTitle, options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: QuickRunNotice.category, actions: [review], intentIdentifiers: [])
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        Task { await model.start() }
        let pending = pendingOpenURLs
        pendingOpenURLs = []
        if !pending.isEmpty { model.openFiles(pending) }
        #if DEBUG
            if PhotosSpike.isRequested { PhotosSpike.start() }
        #endif
        // A drive coming or going changes which library files are there.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshLibrary() }
                })
        }
    }

    /// Quick runs outlive the window, so closing it never quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock drop and Finder's Open With, at cold launch and while running. SwiftUI's `onOpenURL` isn't used, so each
    /// event arrives here once. With the window open the files join Local Files; otherwise they are a quick run.
    func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching {
            model.openFiles(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    /// A click on a quick run's notification (or its Review action) shows the skipped files.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == QuickRunNotice.category,
            let runID = (content.userInfo[QuickRunNotice.runIDKey] as? String).flatMap(UUID.init(uuidString:))
        else { return }
        await model.reviewQuickRun(runID)
    }

    /// Files may have been moved, deleted or restored while the app was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshLibrary()
    }

    private func refreshLibrary() {
        let library = model.library
        Task { await library.refreshAvailability() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            // Pending library saves finish and the running job goes back to the queue for next launch.
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
