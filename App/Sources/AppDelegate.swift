import AppCore
import AppKit
import PhotosLibrary
import QuickRunService
import UserNotifications

/// Owns the model and the updater for the app's lifetime: starts the queue at launch and lets work settle before
/// quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: AppModel
    let updater: Updater
    private var isTerminating = false
    /// Clears Photos input left behind by a crash or quit. It starts as soon as launch begins, overlapping the
    /// window and menu construction; the queue waits for it.
    private var workFolderSweep: Task<Void, Never>?
    private var volumeObservers: [any NSObjectProtocol] = []
    /// The main window lives as long as the app; closing it only hides it.
    private var windowController: MainWindowController?
    private let menuFixups = MenuFixups()
    private var statusItemController: StatusItemController?
    /// Kept for the app's lifetime: `NSApp.servicesProvider` doesn't retain it.
    private var serviceProvider: ServiceProvider?
    /// Movies from the Services menu before launch finished; always a quick run, never the window.
    private var serviceFiles = LaunchBuffer<URL>()
    /// Files opened (Dock drop, Open With) before launch finished; delivered once it has, exactly once.
    private var openedFiles = LaunchBuffer<URL>()
    /// Quick-run notification responses that arrived before launch finished (a click that relaunched the app).
    private var notificationResponses = LaunchBuffer<UUID>()

    /// Set before launch finishes, so a click on a notification that relaunched the app reaches `didReceive`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        menuFixups.start()
        let workFolder = WorkFolder.standard()
        workFolderSweep = Task.detached(priority: .utility) { workFolder.sweep() }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let review = UNNotificationAction(
            identifier: QuickRunNotice.reviewAction, title: QuickRunNotice.reviewActionTitle, options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: QuickRunNotice.category, actions: [review], intentIdentifiers: [])
        ])
    }

    override init() {
        let model = AppModel.shared
        self.model = model
        updater = Updater(relaunchGate: model.relaunchGate)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = MainWindowController(model: model)
        menuFixups.sweep()
        let statusItem = StatusItemController(model: model)
        statusItem.start()
        statusItemController = statusItem
        let provider = ServiceProvider { [weak self] urls in self?.receiveServiceFiles(urls) }
        serviceProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        // Photos input left behind by a crash or quit is cleared before the queue starts, so a job can't create
        // its folder while the sweep runs. Opened files and notification responses stay buffered until the queue
        // runs, so a quick run can't start it early.
        let sweep = workFolderSweep
        Task {
            await sweep?.value
            // Quitting during launch: the queue never starts and nothing is routed.
            guard !isTerminating else { return }
            await model.start()
            routeLaunch()
        }
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

    /// Files that came with the launch are a quick run and leave the window hidden; any other launch (or a
    /// notification click that needs the window) shows it.
    private func routeLaunch() {
        let files = openedFiles.launchFinished()
        let serviced = serviceFiles.launchFinished()
        let responses = notificationResponses.launchFinished()
        if LaunchWindowPlan.plan(
            openedFileCount: files.count + serviced.count, hasNotificationResponse: !responses.isEmpty) == .show
        {
            model.showMainWindow()
        }
        if !files.isEmpty { model.openFiles(files) }
        if !serviced.isEmpty { model.runQuickly(serviced) }
        for runID in responses { Task { await model.reviewQuickRun(runID) } }
    }

    /// Quick runs outlive the window, so closing it never quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A click on the Dock icon brings the window back after it was closed or minimized.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.isMainWindowVisible { model.showMainWindow() }
        return false
    }

    /// Dock drop and Finder's Open With, at cold launch and while running. SwiftUI's `onOpenURL` isn't used, so each
    /// event arrives here once. With the window on screen the files join Local Files; otherwise they are a quick run.
    func application(_ application: NSApplication, open urls: [URL]) {
        let now = openedFiles.receive(urls)
        if !now.isEmpty { model.openFiles(now) }
    }

    /// The Services menu's "Shrink Videos": always a quick run. A service that launched the app waits for launch.
    private func receiveServiceFiles(_ urls: [URL]) {
        let now = serviceFiles.receive(urls)
        if !now.isEmpty { model.runQuickly(now) }
    }

    /// A click on a quick run's notification (or its Review action) shows the skipped files.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == QuickRunNotice.category,
            let runID = (content.userInfo[QuickRunNotice.runIDKey] as? String).flatMap(UUID.init(uuidString:))
        else { return }
        await receiveReviewRequest(runID)
    }

    private func receiveReviewRequest(_ runID: UUID) async {
        let now = notificationResponses.receive([runID])
        for runID in now { await model.reviewQuickRun(runID) }
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
        // Work under way: ask first, unless the system is logging out or restarting. The running job and the rest of
        // the queue are saved as queued below and continue next launch.
        if QuitPolicy.needsConfirmation(
            jobs: model.jobs, isQueuePaused: model.queuePause.isPaused,
            isSessionEnding: QuitConfirmation.isSessionEnding)
            && !QuitConfirmation.confirmStop(
                queueStartsAutomatically: AppSettings.autoStartQueue(model.defaults),
                automaticPause: model.queuePause.automatic)
        {
            return .terminateCancel
        }
        isTerminating = true
        Task {
            // Pending library saves finish and the running job goes back to the queue for next launch.
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
