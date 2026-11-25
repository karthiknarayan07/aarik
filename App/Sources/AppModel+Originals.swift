import AppCore
import AppUI
import DownscaleVideo
import Foundation
import LocalLibrary
import PhotosLibrary

/// How the last attempt to move originals to Recently Deleted went.
enum OriginalsNotice: Equatable {
    /// The user declined Photos' confirmation: nothing was deleted.
    case declined
    case failed(String)
    case moved(count: Int)
}

extension AppModel {
    /// What the pending-deletion bar shows; nil when there is nothing to say.
    var pendingDeletionBar: PendingDeletionBarContent? {
        if isMovingOriginals { return PendingDeletionBarContent(count: pendingOriginals.count, status: .working) }
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
        return PendingDeletionBarContent(count: pendingOriginals.count, status: status)
    }

    /// The bar's button: moves the originals (Photos asks the user to confirm), or dismisses the result.
    func performPendingDeletionAction() {
        if case .moved = originalsNotice {
            originalsNotice = nil
        } else {
            moveOriginalsToRecentlyDeleted()
        }
    }

    /// Asks Photos, once, to move every pending original to Recently Deleted. Photos shows its own confirmation;
    /// declining keeps the list (the bar says so) and nothing is deleted later without asking again.
    func moveOriginalsToRecentlyDeleted() {
        guard !isMovingOriginals, !pendingOriginals.isEmpty else { return }
        isMovingOriginals = true
        originalsNotice = nil
        let store = photoStore
        let pending = pendingDeletions
        Task {
            do {
                let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
                // The jobs say it, and the grid follows by itself: Photos reports the library change.
                for entry in result.moved {
                    send { queue in
                        await queue.updateOutcome(id: entry.jobID) { PhotosDownscaleRunner.markOriginalMoved(&$0) }
                    }
                }
                if !result.kept.isEmpty {
                    originalsNotice = .failed("Photos still lists \(result.kept.count) of them. Try again later.")
                } else if !result.moved.isEmpty {
                    originalsNotice = .moved(count: result.moved.count)
                }
            } catch is CancellationError {
                originalsNotice = .declined
            } catch {
                originalsNotice = .failed(error.localizedDescription)
            }
            pendingOriginals = pending.all
            isMovingOriginals = false
        }
    }

    // MARK: - Overview

    /// Opens the grid that holds an Overview entry and selects it there. Search and filters that would hide it
    /// are cleared first.
    func reveal(_ entry: OverviewSummary.Entry) {
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
