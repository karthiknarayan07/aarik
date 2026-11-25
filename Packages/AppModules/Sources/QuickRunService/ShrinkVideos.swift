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
    /// Videos were handed to a quick run. `outputs` is nil when the action did not wait for the run to end.
    case queued(QuickRunReceipt, outputs: [URL]?)

    /// The sentence the action shows (or Siri says).
    public var message: String {
        switch self {
        case .needsVideos: "Choose the videos to shrink."
        case .nothingMatched: "No videos matched, so nothing was queued."
        case .photosAccessNeeded:
            "The app can't read your Photos library yet. Open the app to allow access, then try again."
        case .failed(let error): error.message
        case .queued(let receipt, let outputs):
            Self.queuedMessage(
                queued: receipt.queuedJobIDs.count, skipped: receipt.skipped.count, finished: outputs != nil,
                started: receipt.startedQueue)
        }
    }

    private static func queuedMessage(queued: Int, skipped: Int, finished: Bool, started: Bool) -> String {
        var sentences: [String] = []
        if queued == 0 {
            sentences.append("Nothing was queued.")
        } else if finished {
            sentences.append("Finished \(videos(queued)).")
        } else if !started {
            sentences.append("Queued \(videos(queued)). They start when you resume the queue.")
        } else {
            sentences.append("Queued \(videos(queued)). A notification says when they're done.")
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

    public init(
        sources: any ShrinkVideosSources, quickRun: QuickRun, now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.sources = sources
        self.quickRun = quickRun
        self.now = now
        self.calendar = calendar
    }

    public func perform(_ request: ShrinkVideosRequest) async -> ShrinkVideosOutcome {
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
        // With auto-start off the jobs wait for the user's Resume, which may never come: don't hold the action.
        guard request.waitForCompletion, receipt.startedQueue else { return .queued(receipt, outputs: nil) }
        return .queued(receipt, outputs: await quickRun.outputs(of: receipt))
    }

    /// The available items of `collection` that the request's date range and resolution let through, in grid order.
    /// A fresh browser, so the window's own filters and selection are never touched.
    func select(from collection: any MediaCollection, request: ShrinkVideosRequest) -> [LibraryItem] {
        let browser = LibraryBrowser(collection: collection)
        if let resolution = request.resolution { browser.quality = QualityFilter(qualities: resolution.buckets) }
        browser.captureRange = request.dateRange?.range(now: now(), calendar: calendar)
        return browser.snapshot.items.filter(\.isAvailable)
    }
}
