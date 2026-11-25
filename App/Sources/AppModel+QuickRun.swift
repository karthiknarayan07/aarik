import AppKit
import AppUI
import DownscaleVideo
import Foundation
import QuickRunService

extension AppModel {
    func makeQuickRun() -> QuickRun {
        QuickRun(
            queue: queue, store: quickRunStore, notifier: QuickRunNotifier(notifier: notifier),
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
    /// notification.
    func runQuickly(_ urls: [URL], overrides: QuickRunOverrides? = nil) {
        notifier.requestAuthorizationOnce()
        Task {
            let receipt = await quickRun.run(urls: urls, overrides: overrides)
            if !receipt.queuedJobIDs.isEmpty, AppSettings.autoStartQueue(defaults) { isQueuePaused = false }
        }
    }

    /// Dock drop and Open With: with the window open the files join Local Files and nothing is queued; with no
    /// window they are a quick run.
    func openFiles(_ urls: [URL]) {
        if isMainWindowOpen {
            addFiles(urls)
        } else {
            runQuickly(urls)
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

/// Posts a finished run's notification through the queue notifier, which stays quiet while the app is frontmost.
struct QuickRunNotifier: QuickRunNotifying {
    let notifier: QueueNotifier

    func post(_ notice: QuickRunNotice) async {
        await notifier.postUnlessFrontmost(
            title: notice.title, body: notice.body, category: QuickRunNotice.category,
            userInfo: [QuickRunNotice.runIDKey: notice.runID.uuidString])
    }
}
