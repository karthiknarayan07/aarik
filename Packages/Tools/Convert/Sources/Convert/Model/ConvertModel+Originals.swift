import AppCore
import AppUI
import Foundation
import LocalLibrary
import PhotosLibrary

/// How the last attempt to move originals to Recently Deleted went.
public enum OriginalsNotice: Equatable {
    /// The user declined Photos' confirmation: nothing was deleted.
    case declined
    case failed(String)
    case moved(count: Int)
}

extension ConvertModel {
    /// What the pending-deletion bar shows; nil when there is nothing to say or the app is not in the foreground.
    public var pendingDeletionBar: PendingDeletionBarContent? {
        guard isForeground else { return nil }
        let ready = pendingOriginals.filter { $0.blocked == nil }
        let held = pendingOriginals.compactMap(\.blocked)
        if isMovingOriginals { return PendingDeletionBarContent(count: ready.count, status: .working) }
        if case .moved(let count) = originalsNotice {
            return PendingDeletionBarContent(count: count, status: .moved(savedBytes: activity.savedBytes))
        }
        guard !pendingOriginals.isEmpty else { return nil }
        let status: PendingDeletionBarContent.Status =
            switch originalsNotice {
            case .declined: .declined
            case .failed(let reason): .failed(reason)
            case .moved, nil: .ready
            }
        var messages: [String] = []
        for block in held where !messages.contains(block.message) { messages.append(block.message) }
        return PendingDeletionBarContent(
            count: ready.count, status: status, heldCount: held.count, heldMessages: messages,
            heldCanRetry: held.contains(where: \.canBeRetried), heldNeedsSettings: held.contains(.limitedAccess))
    }

    /// The bar's button: moves the originals (Photos asks the user to confirm), or dismisses the result.
    public func performPendingDeletionAction() {
        guard isForeground else { return }
        if case .moved = originalsNotice {
            originalsNotice = nil
        } else {
            moveOriginalsToRecentlyDeleted()
        }
    }

    /// "Remove from List": forgets the originals that were kept out of the batch. Nothing is deleted.
    public func removeKeptOriginalsFromList() {
        pendingDeletions.remove(assetIDs: pendingOriginals.filter { $0.blocked != nil }.map(\.assetID))
        pendingOriginals = pendingDeletions.all
    }

    /// "Open System Settings…" for an original that limited access hides.
    public func openPhotosAccessSettings() {
        host.openPhotosAccessSettings()
    }

    /// After a queue run: moves the originals while in the foreground, unless the user already declined for all of
    /// them (then it waits for the user, or for originals from a later run). Never runs in the background.
    public func moveOriginalsAfterRun() {
        guard isForeground else { return }
        guard pendingOriginals.contains(where: { $0.blocked == nil && !declinedOriginals.contains($0.assetID) })
        else { return }
        moveOriginalsToRecentlyDeleted()
    }

    /// Asks Photos, once, to move every pending original that passes the checks to Recently Deleted. Photos shows
    /// its own confirmation; declining keeps the list (the bar says so) and nothing is deleted later without asking
    /// again. Foreground-only: does nothing when the app is not in the foreground.
    public func moveOriginalsToRecentlyDeleted() {
        guard isForeground, !isMovingOriginals, !pendingOriginals.isEmpty else { return }
        isMovingOriginals = true
        originalsNotice = nil
        Task { await runMoveOriginals() }
    }

    func moveOriginalsNow() async {
        guard isForeground, !isMovingOriginals, !pendingOriginals.isEmpty else { return }
        isMovingOriginals = true
        originalsNotice = nil
        await runMoveOriginals()
    }

    private func runMoveOriginals() async {
        let store = photoStore
        let pending = pendingDeletions
        do {
            let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
            // The jobs say it, and the grid follows by itself: Photos reports the library change.
            update(result.moved.map(\.jobID)) { PhotosConvertRunner.markOriginalMoved(&$0) }
            update(result.alreadyGone.map(\.jobID)) { PhotosConvertRunner.markOriginalGone(&$0) }
            for (entry, reason) in result.blocked {
                let message = reason.message
                update([entry.jobID]) { PhotosConvertRunner.markOriginalKept(&$0, because: message) }
            }
            let moved = result.moved.count
            if !result.kept.isEmpty {
                let first = moved > 0 ? "Moved \(moved). " : ""
                originalsNotice = .failed(
                    "\(first)Photos still lists \(result.kept.count) of them. Try again later.")
            } else if moved > 0 {
                originalsNotice = .moved(count: moved)
            }
            declinedOriginals.removeAll()
        } catch is CancellationError {
            declinedOriginals = Set(pending.all.map(\.assetID))
            originalsNotice = .declined
        } catch {
            originalsNotice = .failed(error.localizedDescription)
        }
        pendingOriginals = pending.all
        isMovingOriginals = false
    }

    private func update(_ jobIDs: [UUID], _ change: @escaping @Sendable (inout JobOutcome) -> Void) {
        for id in jobIDs {
            services.send { queue in await queue.updateOutcome(id: id, transform: change) }
        }
    }

    // MARK: - Overview

    /// Opens the grid that holds an Overview entry and selects it there. Search and filters that would hide it
    /// are cleared first.
    public func reveal(_ entry: OverviewSummary.Entry) {
        let target: LibraryBrowser
        switch entry.library {
        case .photos:
            selection = .photosVideos
            target = photosBrowser
        case .localFiles:
            selection = .localFiles
            target = browser
        }
        target.search = ""
        target.quality = QualityFilter()
        target.selection = [entry.id]
    }
}
