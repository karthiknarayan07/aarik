import AppCore
import AppKit
import AppUI
import Convert
import Foundation
import QuickRunService

extension AppModel {
    func makeQuickRun() -> QuickRun {
        QuickRun(
            queue: queue, store: quickRunStore, notifier: QuickRunNotifier(model: self),
            settings: { [unowned self] in await self.quickRunSettings() })
    }

    /// The Settings defaults a quick run converts with (never the window's session choices, so a Replace picked in
    /// the inspector doesn't leak into a run nobody confirmed).
    private func quickRunSettings() -> QuickRunSettings {
        QuickRunSettings(
            preset: preset, saveLocation: AppSettings.defaultSaveLocation(defaults),
            startsQueue: AppSettings.autoStartQueue(defaults))
    }

    /// Converts `urls` in the background: no questions, no window. Skipped files and the result come in one
    /// notification. A run from the menu bar also reports itself in the popover (`menuBarRuns`); `statusEntry` names
    /// its line there.
    func runQuickly(
        _ urls: [URL], overrides: QuickRunOverrides? = nil, origin: QuickRunOrigin = .background,
        statusEntry: UUID? = nil
    ) {
        notifier.requestAuthorizationOnce()
        var entry = statusEntry
        if origin == .statusItem, entry == nil { entry = menuBarRuns.begin(files: urls.count) }
        Task {
            let receipt = await quickRun.run(urls: urls, overrides: overrides, origin: origin)
            if let entry {
                menuBarRuns.queued(
                    entry, runID: receipt.runID, jobIDs: receipt.queuedJobIDs, skipped: receipt.skipped.count,
                    now: Date(), popoverVisible: isStatusPopoverVisible)
            }
            if !receipt.queuedJobIDs.isEmpty, AppSettings.autoStartQueue(defaults) { isQueuePaused = false }
        }
    }

    /// Files dropped on the menu bar item or its popover. Only their names were looked at so far; the files are
    /// checked here, off the main thread, before the run starts. What turns out not to be a video (a folder named
    /// like one, an unreadable file) is counted as skipped, and a drop with no video at all says "Nothing to shrink"
    /// briefly without touching the runs that are going.
    func runFromMenuBar(_ urls: [URL]) {
        let entry = menuBarRuns.begin(files: urls.count)
        Task {
            let split = await Task.detached(priority: .userInitiated) { MovieDropFilter.partition(urls) }.value
            menuBarRuns.checked(entry, movies: split.movies.count, rejected: split.others.count, now: Date())
            guard !split.movies.isEmpty else {
                expireMenuBarNotice()
                return
            }
            runQuickly(split.movies, origin: .statusItem, statusEntry: entry)
        }
    }

    /// Takes the brief message off once its time is up.
    private func expireMenuBarNotice() {
        Task {
            try? await Task.sleep(for: .seconds(MenuBarRunBoard.noticeLifetime + 0.1))
            menuBarRuns.prune(now: Date())
        }
    }

    /// The popover is about to open: results already seen go, and the rest count as seen.
    func menuBarPopoverWillOpen() {
        isStatusPopoverVisible = true
        menuBarRuns.popoverOpened(now: Date())
    }

    /// Dock drop and Open With: with the window on screen the files join Local Files and nothing is queued;
    /// otherwise they are a quick run.
    func openFiles(_ urls: [URL]) {
        switch OpenedFilesRoute.route(windowVisible: isMainWindowVisible) {
        case .addToLibrary: addFiles(urls)
        case .quickRun: runQuickly(urls)
        }
    }

    /// A quick run's notification was clicked: shows the window with the run's skipped files in Local Files,
    /// selected.
    func reviewQuickRun(_ runID: UUID) async {
        await reviewQuickRuns([runID])
    }

    /// The same for several runs at once (the popover's "Show Skipped…" when more than one run is listed).
    func reviewQuickRuns(_ runIDs: [UUID]) async {
        var urls: [URL] = []
        for runID in runIDs { urls += await quickRun.skippedURLs(runID: runID) }
        showMainWindow()
        guard !urls.isEmpty else { return }
        addFiles(urls)
        await library.waitUntilIdle()
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        browser.selection = Set(
            library.items.filter { $0.fileURL.map { wanted.contains($0.standardizedFileURL.path) } ?? false }
                .map(\.id))
    }
}

/// Posts a finished run's notification. It stays quiet only when the app is active with its window on screen: a
/// Dock drop activates a windowless app, and that run's notification is the only feedback.
struct QuickRunNotifier: QuickRunNotifying {
    /// Weak: the model owns the quick run that owns this.
    weak let model: AppModel?

    func post(_ notice: QuickRunNotice) async {
        await model?.postQuickRunNotice(notice)
    }
}

extension AppModel {
    func postQuickRunNotice(_ notice: QuickRunNotice) {
        // The popover lists every menu-bar run's result, however the others stand; the banner below follows the policy
        // for each run on its own. The result is kept even if it arrives before the run's entry is attached.
        if notice.origin == .statusItem {
            menuBarRuns.finished(
                runID: notice.runID, tally: notice.tally, now: Date(), popoverVisible: isStatusPopoverVisible)
            announce(MenuBarRunBoard.doneText(notice.tally))
        }
        guard
            NotificationPolicy.shouldPost(
                origin: notice.origin, appIsActive: NSApp.isActive, windowOnScreen: isMainWindowVisible,
                popoverVisible: isStatusPopoverVisible)
        else { return }
        notifier.post(
            title: notice.title, body: notice.body, category: QuickRunNotice.category,
            userInfo: [QuickRunNotice.runIDKey: notice.runID.uuidString])
    }
}

extension AppModel {
    /// Says `text` to VoiceOver, so a person who dropped videos hears the result without going back to the popover.
    func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}
