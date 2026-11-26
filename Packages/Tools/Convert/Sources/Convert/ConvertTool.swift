import AppCore
import Foundation
import MediaEngine
import PhotosLibrary
import UniformTypeIdentifiers

/// Where the converted file goes.
public enum SaveDestination: Codable, Sendable, Equatable {
    case nextToOriginal
    case folder(bookmark: Data)
    case replace
    /// The app's Documents directory (e.g. On My iPhone › <app> on iOS).
    case documents
}

/// Where a Photos video's converted copy goes.
public enum PhotosDestination: Codable, Sendable, Equatable {
    /// Photos, as a new video next to the original (the default; the original is never touched).
    case newAsset
    /// Photos, as a new video; the original is then moved to Recently Deleted (after a batch confirmation).
    case replace
    /// A folder on this Mac, with the normal naming; nothing in Photos changes.
    case folder(bookmark: Data)
}

/// The settings a Convert job carries, encoded as JSON in `Job.settings`.
public struct ConvertJobSettings: Codable, Sendable, Equatable {
    /// Which operation to run; jobs saved before this existed decode as `.shrink`.
    public var kind: ConvertJobKind
    public var preset: Preset
    public var saveTo: SaveDestination
    /// When set (for `.shrink`), wins over `preset`.
    public var custom: DownscaleSpec?
    /// What the planner predicted, when the job was added, that converting loses (display names, as shown);
    /// empty for nothing. Nil for jobs saved before this was recorded.
    public var predictedLost: [String]?
    /// The keys of the items in `predictedLost`: what the runner checks a loss against. Nil for jobs saved before
    /// keys were recorded (the runner then compares names).
    public var predictedLostKeys: [String]?
    /// For a Photos job: where its copy goes (`saveTo` is not used). Nil for a job on a file.
    public var photosDestination: PhotosDestination?
    /// For a Photos job: the video's file name in Photos, for showing in the lists (the job's source is an
    /// address, not a file).
    public var photosFileName: String?

    public init(
        kind: ConvertJobKind = .shrink, preset: Preset = .balanced, saveTo: SaveDestination,
        custom: DownscaleSpec? = nil, predictedLost: [String]? = nil,
        predictedLostKeys: [String]? = nil, photosDestination: PhotosDestination? = nil,
        photosFileName: String? = nil
    ) {
        self.kind = kind
        self.preset = preset
        self.saveTo = saveTo
        self.custom = custom
        self.predictedLost = predictedLost
        self.predictedLostKeys = predictedLostKeys
        self.photosDestination = photosDestination
        self.photosFileName = photosFileName
    }

    /// Jobs saved before `kind` existed have no `kind` key; they decode as `.shrink`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(ConvertJobKind.self, forKey: .kind) ?? .shrink
        preset = try container.decode(Preset.self, forKey: .preset)
        saveTo = try container.decode(SaveDestination.self, forKey: .saveTo)
        custom = try container.decodeIfPresent(DownscaleSpec.self, forKey: .custom)
        predictedLost = try container.decodeIfPresent([String].self, forKey: .predictedLost)
        predictedLostKeys = try container.decodeIfPresent([String].self, forKey: .predictedLostKeys)
        photosDestination = try container.decodeIfPresent(PhotosDestination.self, forKey: .photosDestination)
        photosFileName = try container.decodeIfPresent(String.self, forKey: .photosFileName)
    }

    public func spec(for inventory: MetadataInventory, byteSize: Int64) -> DownscaleSpec {
        spec(for: SourceProfile(inventory: inventory, byteSize: byteSize))
    }

    func spec(for profile: SourceProfile) -> DownscaleSpec {
        switch kind {
        case .shrink: custom ?? preset.spec(for: profile)
        case .compress(let compressPreset): compressPreset.spec(for: profile)
        }
    }
}

/// The Convert tool: shrinks video, from a file or from the Photos library. Its two job kinds keep the ids saved jobs
/// already carry.
public struct ConvertTool: Tool {
    public static let toolID = "downscale-video"
    /// The same conversion on a video in the Photos library; its jobs have an `x-photos-asset:` source.
    public static let photosToolID = "downscale-video-photos"

    /// The user-facing name. The ids above are what is stored, so renaming this changes no saved job.
    public static let title = "Convert"
    public static let systemImage = "arrow.down.right.and.arrow.up.left"

    public static let descriptor = ToolDescriptor(id: toolID, name: title, symbol: systemImage, category: .video)

    public var id: String { Self.toolID }
    public var title: String { Self.title }
    public var systemImage: String { Self.systemImage }
    public var platforms: ToolPlatforms { [.macOS, .iOS] }
    public var jobKinds: [JobKind] { [Self.fileKind, Self.photosKind] }

    public static let fileKind = JobKind(rawValue: toolID)
    public static let photosKind = JobKind(rawValue: photosToolID)

    private let photoStore: any PhotoStore
    private let workFolder: WorkFolder
    private let pendingDeletions: PendingDeletions
    private let originalsBackup: ConvertRunner.BackupProvider

    /// `originalsBackup` is asked at each Replace, so a setting changed in Settings applies to the next one.
    public init(
        photoStore: any PhotoStore, pendingDeletions: PendingDeletions, workFolder: WorkFolder = .standard(),
        originalsBackup: @escaping ConvertRunner.BackupProvider = { nil }
    ) {
        self.photoStore = photoStore
        self.pendingDeletions = pendingDeletions
        self.workFolder = workFolder
        self.originalsBackup = originalsBackup
    }

    /// Video: a movie file, or a video in the Photos library.
    public func accepts(_ input: MediaInput) -> Bool {
        switch input {
        case .file(let url):
            guard url.isFileURL else { return false }
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
        case .photosAsset(_, let isVideo):
            return isVideo
        }
    }

    public func runner(for kind: JobKind) -> (any JobRunner)? {
        switch kind {
        case Self.fileKind:
            ConvertRunner(originalsBackup: originalsBackup)
        case Self.photosKind:
            // Photos jobs fetch into the Work folder, which the launch sweep clears before the queue starts.
            PhotosConvertRunner(
                store: photoStore, workFolder: workFolder, pendingDeletions: pendingDeletions,
                originalsBackup: originalsBackup)
        default:
            nil
        }
    }
}
