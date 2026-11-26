import DownscaleVideo
import Foundation
import LocalLibrary

/// Where the action finds videos when it is given none: the app's own libraries.
@MainActor
public protocol ShrinkVideosSources: AnyObject {
    /// The Local Files library, once what was saved has loaded.
    func localLibrary() async -> any MediaCollection
    /// The Photos library, or nil without access. Never shows the system's access prompt: a run that starts in the
    /// background has nobody to answer it.
    func photosLibrary() async -> (any MediaCollection)?
}

/// What happened after the jobs were queued.
public enum ShrinkVideosWait: Sendable, Equatable {
    /// The action was not asked to wait.
    case notRequested
    /// Every job ended; see `QuickRunWait.finished`.
    case finished(outputs: [URL], converted: Int)
    /// The queue is paused, so waiting would not end.
    case paused
    /// The app quit, or the wait was cancelled, before the jobs ended.
    case interrupted

    /// The files made, or nil when the run did not finish under the action's eyes.
    public var outputs: [URL]? {
        if case .finished(let outputs, _) = self { outputs } else { nil }
    }
}

/// What running the action did.
public enum ShrinkVideosOutcome: Sendable, Equatable {
    /// No videos were given and nothing was chosen to pick them by.
    case needsVideos
    /// The selection matched nothing; nothing was queued.
    case nothingMatched
    /// The selection is in Photos and the app may not read it.
    case photosAccessNeeded
    /// The request can't run as given.
    case failed(ShrinkVideosError)
    /// Videos were handed to a quick run.
    case queued(QuickRunReceipt, ShrinkVideosWait)

    /// The files the run made, when the action waited for it to finish.
    public var outputs: [URL]? {
        if case .queued(_, let wait) = self { wait.outputs } else { nil }
    }

    /// The sentence the action shows (or Siri says).
    public var message: String {
        switch self {
        case .needsVideos: "Choose the videos to shrink."
        case .nothingMatched: "No videos matched, so nothing was queued."
        case .photosAccessNeeded:
            "The app can't read your Photos library yet. Open the app to allow access, then try again."
        case .failed(let error): error.message
        case .queued(let receipt, let wait):
            Self.queuedMessage(queued: receipt.queuedJobIDs.count, skipped: receipt.skipped.count, wait: wait)
        }
    }

    /// The message with sentences about how the run differed from what was asked (a folder that wasn't available,
    /// videos that couldn't be read).
    public func message(adding notes: [String]) -> String {
        ([message] + notes).joined(separator: " ")
    }

    private static func queuedMessage(queued: Int, skipped: Int, wait: ShrinkVideosWait) -> String {
        var sentences: [String] = []
        if queued == 0 {
            sentences.append("Nothing was queued.")
        } else {
            switch wait {
            case .notRequested:
                sentences.append("Queued \(videos(queued)). A notification says when they're done.")
            case .finished(_, let converted):
                sentences.append(converted > 0 ? "Shrank \(videos(converted))." : "Nothing was converted.")
            case .paused:
                sentences.append(
                    "Queued \(videos(queued)). The queue is paused, so they'll convert when you resume it.")
            case .interrupted:
                sentences.append(
                    "Queued \(videos(queued)). The app quit first, so they'll continue when it opens again.")
            }
        }
        if skipped > 0 { sentences.append("\(skipped) skipped.") }
        return sentences.joined(separator: " ")
    }

    private static func videos(_ count: Int) -> String { count == 1 ? "1 video" : "\(count) videos" }
}

/// The Shrink Videos action behind Shortcuts, the Finder Quick Action, Siri and Spotlight: turns a request into
/// one quick run. Files handed in win; without them the date range, resolution and source pick videos from the
/// app's libraries with the grid's own filters (`LibraryBrowser`, `QualityFilter`, the capture range). It never
/// uses the language model.
@MainActor
public final class ShrinkVideos {
    private let sources: any ShrinkVideosSources
    private let quickRun: QuickRun
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let pollInterval: Duration

    public init(
        sources: any ShrinkVideosSources, quickRun: QuickRun, now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current, pollInterval: Duration = .seconds(1)
    ) {
        self.sources = sources
        self.quickRun = quickRun
        self.now = now
        self.calendar = calendar
        self.pollInterval = pollInterval
    }

    /// `didQueue` runs as soon as this run's jobs are in the queue, before the action waits for them.
    public func perform(
        _ request: ShrinkVideosRequest, didQueue: @MainActor (QuickRunReceipt) -> Void = { _ in }
    ) async -> ShrinkVideosOutcome {
        let overrides: QuickRunOverrides
        do { overrides = try request.overrides() } catch let error as ShrinkVideosError {
            return .failed(error)
        } catch {
            return .failed(.folderUnavailable)
        }
        let receipt: QuickRunReceipt
        if !request.files.isEmpty {
            receipt = await quickRun.run(urls: request.files, overrides: overrides)
        } else if request.hasSelection {
            switch request.source ?? .localFiles {
            case .localFiles:
                let urls = select(from: await sources.localLibrary(), request: request).compactMap(\.fileURL)
                if urls.isEmpty { return .nothingMatched }
                receipt = await quickRun.run(urls: urls, overrides: overrides)
            case .photos:
                if request.format == .h264 { return .failed(.h264NotForPhotos) }
                guard let library = await sources.photosLibrary() else { return .photosAccessNeeded }
                let videos = select(from: library, request: request).compactMap { item in
                    item.photosIdentifier.map {
                        QuickRunPhotoVideo(
                            assetID: $0, name: item.name, isCinematic: item.badges.contains(.cinematic),
                            isHDR: item.badges.contains(.hdr) || item.badges.contains(.dolbyVision))
                    }
                }
                if videos.isEmpty { return .nothingMatched }
                receipt = await quickRun.runPhotos(videos, overrides: overrides)
            }
        } else {
            return .needsVideos
        }
        didQueue(receipt)
        guard request.waitForCompletion else { return .queued(receipt, .notRequested) }
        // With auto-start off nothing will run until the user resumes: don't hold the action.
        guard receipt.startedQueue else { return .queued(receipt, .paused) }
        switch await quickRun.wait(for: receipt, pollInterval: pollInterval) {
        case .finished(let outputs, let converted):
            return .queued(receipt, .finished(outputs: outputs, converted: converted))
        case .paused: return .queued(receipt, .paused)
        case .interrupted: return .queued(receipt, .interrupted)
        }
    }

    /// The available items of `collection` that the request's date range and resolution let through, in grid order.
    /// A fresh browser, so the window's own filters and selection are never touched.
    func select(from collection: any MediaCollection, request: ShrinkVideosRequest) -> [LibraryItem] {
        let browser = LibraryBrowser(collection: collection)
        // A video whose frame rate is unknown (Photos without its index) has no bucket of its own: it is let through
        // the filter and kept when its size says it has the resolution.
        if let resolution = request.resolution {
            browser.quality = QualityFilter(qualities: resolution.buckets.union([.unknown]))
        }
        browser.captureRange = request.dateRange?.range(now: now(), calendar: calendar)
        return browser.snapshot.items.filter { item in
            guard item.isAvailable else { return false }
            guard let resolution = request.resolution, QualityBucket(item: item) == .unknown else { return true }
            return resolution.includes(pixelSize: item.pixelSize)
        }
    }
}
