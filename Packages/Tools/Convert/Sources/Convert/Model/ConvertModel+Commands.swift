import AppCore
import AppUI
import Foundation
import LocalLibrary

extension ConvertModel {
    /// What the menus' commands decide from (see `AppCommands`).
    public var commandContext: AppCommandContext {
        AppCommandContext(
            canRemoveFromLibrary: canRemoveSelectionFromLibrary, canAddToQueue: canAddSelectionToQueue,
            isQueuePaused: isQueuePaused, failedJobCount: failedJobs.count)
    }

    /// The sections ⌘1 to ⌘9 go to, in the sidebar's order. Media-type filters and tools are reached in the sidebar.
    public static let goDestinations: [VideoPage] = [
        .overview, .photosVideos, .localFiles, .queue, .completed, .keptAsIs, .failed,
    ]

    /// The browser the View menu's Group By and Sort By act on: the page that is showing; nil on the Activity pages.
    public var activeBrowser: LibraryBrowser? {
        if isPhotosPage { return photosBrowser }
        return selection?.showsLibrary == true ? browser : nil
    }

    /// The toolbar's Add to Queue button: "Add to Queue", or "Add 3 to Queue" for several videos.
    public var toolbarAddToQueueTitle: String {
        QueueButtonTitle.toolbarTitle(count: isPhotosPage ? selectedPhotoItems.count : queueableItems.count)
    }

    public func perform(_ command: AppCommandID) {
        host.showMainWindow()
        switch command {
        case .addVideos:
            if selection?.showsLibrary != true { selection = .localFiles }
            isImporterPresented = true
        case .removeFromLibrary: removeSelectionFromLibrary()
        case .addToQueue: requestAddSelectionToQueue()
        case .pauseOrResumeQueue: toggleQueuePaused()
        case .retryAllFailed: retryAllFailed()
        }
    }

    public func showQueue() {
        host.showMainWindow()
        selection = .queue
    }

    // MARK: - Undo

    /// The window's undo manager, which Edit → Undo and Redo use.
    private var undoManager: UndoManager? { host.undoManager() }

    /// Offers Edit → Undo Remove from Library. Undo adds the files back (they are scanned again, so they return
    /// as new items); Redo removes them again.
    public func registerUndo(of removal: LibraryRemoval) {
        guard !removal.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undoRemoval(removal) }
        }
        undoManager.setActionName(LibraryRemoval.actionName)
    }

    private func undoRemoval(_ removal: LibraryRemoval) {
        library.add(removal.urls)
        selection = .localFiles
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.redoRemoval(removal) }
        }
        undoManager?.setActionName(LibraryRemoval.actionName)
    }

    private func redoRemoval(_ removal: LibraryRemoval) {
        let ids = removal.ids(in: library.items)
        guard !ids.isEmpty else { return }
        removeFromLibrary(ids, undoable: false)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undoRemoval(removal) }
        }
        undoManager?.setActionName(LibraryRemoval.actionName)
    }

    // MARK: - Activity lists

    public func rowFacts(of job: Job, in kind: JobListKind) -> JobRowFacts {
        let hasFile: Bool
        if kind == .completed, case .completed(let outcome) = job.state {
            hasFile = outcome.output.isFileURL
        } else {
            hasFile = job.source.isFileURL
        }
        if case .running = job.state { return JobRowFacts(isRunning: true, hasFile: hasFile) }
        return JobRowFacts(hasFile: hasFile)
    }

    /// The jobs with these ids, in list order.
    public func jobs(withIDs ids: Set<UUID>) -> [Job] { jobs.filter { ids.contains($0.id) } }

    public func facts(of ids: Set<UUID>, in kind: JobListKind) -> [JobRowFacts] {
        jobs(withIDs: ids).map { rowFacts(of: $0, in: kind) }
    }

    public func contextMenu(for ids: Set<UUID>, in kind: JobListKind) -> [JobListCommand] {
        JobListActions.contextMenu(kind: kind, rows: facts(of: ids, in: kind))
    }

    /// Double-click or Return.
    public func performPrimaryAction(on ids: Set<UUID>, in kind: JobListKind) {
        guard let action = JobListActions.primary(kind: kind, rows: facts(of: ids, in: kind)) else { return }
        perform(action, on: ids, in: kind)
    }

    /// Delete.
    public func performDelete(on ids: Set<UUID>, in kind: JobListKind) {
        guard let action = JobListActions.deleteAction(kind: kind, rows: facts(of: ids, in: kind)) else { return }
        perform(action, on: ids, in: kind)
    }

    public func perform(_ action: JobListAction, on ids: Set<UUID>, in kind: JobListKind) {
        let selected = jobs(withIDs: ids)
        switch action {
        case .showInFinder:
            let urls = selected.compactMap { job -> URL? in
                if kind == .completed, case .completed(let outcome) = job.state {
                    return outcome.output.isFileURL ? outcome.output : nil
                }
                return job.source.isFileURL ? job.source : nil
            }
            if !urls.isEmpty { host.reveal(urls) }
        case .retry:
            for job in selected { retry(job) }
        case .removeFromQueue:
            for job in selected { cancel(job) }
        case .removeFromList:
            for job in selected { remove(job) }
        }
    }
}
