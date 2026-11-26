import AppCore
import DownscaleVideo
import Foundation
import MediaEngine

/// A file a quick run left out, and why.
public struct QuickRunSkip: Codable, Sendable, Equatable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// What a caller (a Shortcuts action, say) may change for one quick run; anything left nil comes from the saved
/// settings.
public struct QuickRunOverrides: Sendable, Equatable {
    public var preset: Preset?
    public var saveLocation: SaveLocation?
    /// The format to write; nil keeps the preset's own (HEVC).
    public var codec: VideoCodec?

    public init(preset: Preset? = nil, saveLocation: SaveLocation? = nil, codec: VideoCodec? = nil) {
        self.preset = preset
        self.saveLocation = saveLocation
        self.codec = codec
    }
}

/// A video in the Photos library, as a quick run needs to know it. Nothing here is the video itself.
public struct QuickRunPhotoVideo: Sendable, Equatable {
    public let assetID: String
    public let name: String
    public let isCinematic: Bool
    public let isHDR: Bool

    public init(assetID: String, name: String, isCinematic: Bool, isHDR: Bool) {
        self.assetID = assetID
        self.name = name
        self.isCinematic = isCinematic
        self.isHDR = isHDR
    }
}

/// The saved defaults a quick run converts with.
public struct QuickRunSettings: Sendable, Equatable {
    public var preset: Preset
    public var saveLocation: SaveLocation
    /// Whether adding jobs also starts the queue (the Settings auto-start choice).
    public var startsQueue: Bool

    public init(preset: Preset, saveLocation: SaveLocation, startsQueue: Bool = true) {
        self.preset = preset
        self.saveLocation = saveLocation
        self.startsQueue = startsQueue
    }
}

/// What `QuickRun.run` did with the files it was given.
public struct QuickRunReceipt: Sendable, Equatable {
    public let runID: UUID
    /// The jobs added to the queue, in the order given.
    public let queuedJobIDs: [UUID]
    public let skipped: [QuickRunSkip]
    /// Sentences about how the run differs from the saved settings, such as a Replace turned into a copy.
    public let notes: [String]
    /// Whether the queue was started for this run. When it wasn't (auto-start is off), the jobs wait until the user
    /// resumes the queue, so nothing should wait for them to finish.
    public let startedQueue: Bool

    public init(
        runID: UUID, queuedJobIDs: [UUID], skipped: [QuickRunSkip], notes: [String], startedQueue: Bool = true
    ) {
        self.runID = runID
        self.queuedJobIDs = queuedJobIDs
        self.skipped = skipped
        self.notes = notes
        self.startedQueue = startedQueue
    }
}

/// How waiting for a run ended.
public enum QuickRunWait: Sendable, Equatable {
    /// Every job ended. `outputs` are the files the converted ones made; `converted` counts every converted job,
    /// Photos ones too (their copies are in Photos or in the folder chosen, not in `outputs`).
    case finished(outputs: [URL], converted: Int)
    /// The queue is paused and none of the run's jobs is running, so nothing will move until the user resumes.
    case paused
    /// The queue stopped under the wait: the app is quitting, or the wait was cancelled.
    case interrupted
}

/// Where a quick run was started from.
public enum QuickRunOrigin: String, Codable, Sendable {
    /// Dock drop, Open With, Services, Shortcuts: nothing on screen reports the run but its notification.
    case background
    /// The menu bar item or its popover, which shows the run's status itself while it is open.
    case statusItem
}

/// How a finished run ended, in files.
public struct QuickRunTally: Sendable, Equatable {
    public let converted: Int
    public let skipped: Int
    public let failed: Int

    public init(converted: Int, skipped: Int, failed: Int) {
        self.converted = converted
        self.skipped = skipped
        self.failed = failed
    }
}

/// The notification a finished run posts.
public struct QuickRunNotice: Sendable, Equatable {
    public static let category = "QUICK_RUN_DONE"
    public static let reviewAction = "REVIEW_SKIPPED"
    public static let reviewActionTitle = "Review skipped files"
    /// The `userInfo` key holding the run's ID, for the response handler.
    public static let runIDKey = "runID"

    public let runID: UUID
    public let title: String
    public let body: String
    public let origin: QuickRunOrigin
    public let tally: QuickRunTally

    public init(
        runID: UUID, title: String, body: String, origin: QuickRunOrigin = .background,
        tally: QuickRunTally = QuickRunTally(converted: 0, skipped: 0, failed: 0)
    ) {
        self.runID = runID
        self.title = title
        self.body = body
        self.origin = origin
        self.tally = tally
    }
}

/// A video's size and metadata, as the planner needs them.
public struct QuickRunSource: Sendable, Equatable {
    public let byteSize: Int64
    public let inventory: MetadataInventory

    public init(byteSize: Int64, inventory: MetadataInventory) {
        self.byteSize = byteSize
        self.inventory = inventory
    }
}

/// The part of the job queue a quick run uses.
public protocol QuickRunQueue: Sendable {
    var jobs: [Job] { get async }
    func enqueue(_ jobs: [Job]) async -> [Job]
    func resume() async
    func isPaused() async -> Bool
    func updates() async -> AsyncStream<[Job]>
}

extension JobQueue: QuickRunQueue {}

/// Posts the notification of a finished run. The app's implementation keeps the rule that nothing is posted while
/// the app is frontmost.
public protocol QuickRunNotifying: Sendable {
    func post(_ notice: QuickRunNotice) async
}

/// Reads a file's size and metadata; nil when it isn't a readable video.
public protocol QuickRunInspecting: Sendable {
    func inspect(_ url: URL) async -> QuickRunSource?
}
