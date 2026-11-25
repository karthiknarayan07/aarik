import AppCore
import AppKit
import AppUI
import DownscaleVideo
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
    /// notification. A run from the menu bar also reports itself in the popover (`quickRunStatus`).
    func runQuickly(_ urls: [URL], overrides: QuickRunOverrides? = nil, origin: QuickRunOrigin = .background) {
        notifier.requestAuthorizationOnce()
        if origin == .statusItem { quickRunStatus = QuickRunStatus(phase: .checking(files: urls.count)) }
        Task {
            let receipt = await quickRun.run(urls: urls, overrides: overrides, origin: origin)
            if origin == .statusItem { show(receipt) }
            if !receipt.queuedJobIDs.isEmpty, AppSettings.autoStartQueue(defaults) { isQueuePaused = false }
        }
    }

    /// Files dropped on the menu bar item or its popover. Only their names were looked at so far; the files are
    /// checked here, off the main thread, before the run starts.
    func runFromMenuBar(_ urls: [URL]) {
        quickRunStatus = QuickRunStatus(phase: .checking(files: urls.count))
        Task {
            let movies = await Task.detached(priority: .userInitiated) { MovieDropFilter.movies(in: urls) }.value
            guard !movies.isEmpty else {
                quickRunStatus = QuickRunStatus(phase: .finished(QuickRunTally(converted: 0, skipped: 0, failed: 0)))
                return
            }
            runQuickly(movies, origin: .statusItem)
        }
    }

    /// What the popover says once the run's files are sorted into queued and skipped. A finished run may already
    /// have said so (every file skipped), and a newer run's status is left alone.
    private func show(_ receipt: QuickRunReceipt) {
        if let current = quickRunStatus {
            if let id = current.runID, id != receipt.runID { return }
            if current.runID == receipt.runID, !current.isActive { return }
        }
        if receipt.queuedJobIDs.isEmpty {
            quickRunStatus = QuickRunStatus(
                runID: receipt.runID,
                phase: .finished(QuickRunTally(converted: 0, skipped: receipt.skipped.count, failed: 0)))
        } else {
            quickRunStatus = QuickRunStatus(
                runID: receipt.runID, phase: .running(videos: receipt.queuedJobIDs.count),
                jobIDs: Set(receipt.queuedJobIDs))
        }
    }

    /// A run whose jobs were all removed by hand never gets a notice; its status would say "Shrinking" forever.
    func clearStaleQuickRunStatus(jobs: [Job]) {
        guard let status = quickRunStatus, status.isActive, !status.jobIDs.isEmpty else { return }
        let present = Set(jobs.map(\.id))
        if status.jobIDs.isDisjoint(with: present) { quickRunStatus = nil }
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
        let urls = await quickRun.skippedURLs(runID: runID)
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
        if notice.origin == .statusItem, quickRunStatus == nil || quickRunStatus?.runID == notice.runID {
            quickRunStatus = QuickRunStatus(runID: notice.runID, phase: .finished(notice.tally))
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
