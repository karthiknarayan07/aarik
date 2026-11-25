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

    public init(runID: UUID, title: String, body: String) {
        self.runID = runID
        self.title = title
        self.body = body
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
