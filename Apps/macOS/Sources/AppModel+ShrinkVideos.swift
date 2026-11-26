import AppUI
import Convert
import Foundation
import LocalLibrary
import PhotosLibrary
import QuickRunService

/// A video that reached the action as data only, with the name it came with.
struct ShrinkDataInput: Sendable {
    let name: String
    let data: Data
}

extension AppModel {
    func makeShrinkVideosAction() -> ShrinkVideos {
        ShrinkVideos(sources: ShrinkVideosLibraries(model: self), quickRun: quickRun)
    }

    /// Runs the Shortcuts, Siri and Spotlight action. An intent that launched the app can arrive before launch has
    /// finished; it waits until the work folder is swept and the queue is running.
    ///
    /// `request.files` holds the videos that have a file. `dataInputs` are the ones that came as data only: they are
    /// copied into the app's Staging folder (off the main actor), converted from there, and their copies removed when
    /// their jobs end. Their results go to a folder you can see, never next to the copy. `providedCount` is how many
    /// videos the caller was given, so that videos that couldn't be read are reported instead of falling through to
    /// a selection.
    func shrinkVideos(
        _ request: ShrinkVideosRequest, dataInputs: [ShrinkDataInput] = [], providedCount: Int
    ) async -> (outcome: ShrinkVideosOutcome, notes: [String]) {
        intentRunHandler?()
        await waitUntilStarted()
        notifier.requestAuthorizationOnce()
        var request = request
        var notes: [String] = []
        var staged: [URL] = []
        if !dataInputs.isEmpty {
            let inputs = stagedInputs
            staged = await Task.detached {
                dataInputs.compactMap { try? inputs.stage(name: $0.name, data: $0.data) }
            }.value
            request.files += staged
            if !staged.isEmpty {
                guard let (folder, note) = visibleOutputFolder() else {
                    for url in staged { stagedInputs.remove(url) }
                    return (.failed(.folderUnavailable), [])
                }
                request.redirectedFolder = folder
                if let note { notes.append(note) }
            }
        }
        if providedCount > 0, request.files.isEmpty { return (.failed(.inputsUnreadable), []) }
        let dropped = providedCount - request.files.count
        if dropped > 0 {
            notes.append("Couldn't read \(dropped) of \(providedCount) videos.")
        }
        let stagedCopies = Set(staged)
        let outcome = await shrinkVideosAction.perform(request) { [unowned self] receipt in
            if !receipt.queuedJobIDs.isEmpty, receipt.startedQueue { isQueuePaused = false }
            // A copy whose job was never queued is not needed; the others are removed when their jobs end.
            let notQueued = Set(receipt.skipped.map(\.url.standardizedFileURL))
            for url in stagedCopies {
                if notQueued.contains(url.standardizedFileURL) {
                    stagedInputs.remove(url)
                } else {
                    stagedWatch.insert(url)
                }
            }
        }
        // Nothing was queued at all (the run didn't start): nothing will read the copies.
        if case .queued = outcome {} else { for url in staged { stagedInputs.remove(url) } }
        return (outcome, notes)
    }

    /// Where results of data-only videos go: the Settings save folder when one is set and usable, else the user's
    /// Movies folder, with a sentence saying so when the Settings folder was set but isn't available. Outputs never
    /// overwrite (their names are made unique).
    private func visibleOutputFolder() -> (URL, String?)? {
        let wantsFolder = defaults.string(forKey: AppSettings.Keys.defaultSaveTo) == SaveLocation.Choice.folder.rawValue
        var note: String?
        if wantsFolder {
            let saved = AppSettings.defaultSaveLocation(defaults)
            var probe = SaveLocation()
            if saved.choice == .folder, let folder = saved.folder, (try? probe.setFolder(folder)) != nil {
                return (folder, nil)
            }
            note = "The save folder in Settings isn't available, so the videos went to Movies."
        }
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return (movies, note)
    }

    /// Removes the copies no job needs any more (finished, kept as is, cancelled, or a failed job taken out of the
    /// queue); a failed job keeps its copy so Retry works. The queue itself is asked, so a job just added is never
    /// missed.
    func releaseStagedInputs() async {
        stagedWatch = stagedInputs.release(watching: stagedWatch, jobs: await queue.jobs)
    }
}

/// The libraries the action picks from when it is given no files. It only reads: Photos is never asked for access
/// from here, because a run started from Shortcuts or Siri has no window to show the system prompt in.
@MainActor
final class ShrinkVideosLibraries: ShrinkVideosSources {
    private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    func localLibrary() async -> any MediaCollection {
        await model.library.waitUntilIdle()
        return model.library
    }

    func photosLibrary() async -> (any MediaCollection)? {
        // Reads the current authorization without prompting, and loads the videos when reading is allowed.
        await model.photos.start()
        guard model.photos.authorization.allowsReading else { return nil }
        await model.photos.waitUntilIdle()
        return model.photos
    }
}
