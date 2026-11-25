import AppUI
import Foundation
import LocalLibrary
import PhotosLibrary
import QuickRunService

extension AppModel {
    func makeShrinkVideosAction() -> ShrinkVideos {
        ShrinkVideos(
            sources: ShrinkVideosLibraries(model: self), quickRun: quickRun,
            didQueue: { [unowned self] receipt in
                if !receipt.queuedJobIDs.isEmpty, receipt.startedQueue { isQueuePaused = false }
            })
    }

    /// Runs the Shortcuts, Siri and Spotlight action. An intent that launched the app can arrive before launch has
    /// finished; it waits until the work folder is swept and the queue is running.
    func shrinkVideos(_ request: ShrinkVideosRequest) async -> ShrinkVideosOutcome {
        await waitUntilStarted()
        notifier.requestAuthorizationOnce()
        return await shrinkVideosAction.perform(request)
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
