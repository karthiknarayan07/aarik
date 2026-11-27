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
    /// Image conversion settings when this job operates on an image (`convert-image` / `convert-image-photos`).
    public var imageSpec: ImageSpec?
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
    /// What the planner estimated converting would save, when the job was added; the Queue's Start button adds
    /// these up. Nil when unknown (an older job, or a video that would be kept as it is).
    public var estimatedSavedBytes: Int64?

    public init(
        kind: ConvertJobKind = .shrink, preset: Preset = .balanced, saveTo: SaveDestination,
        custom: DownscaleSpec? = nil, imageSpec: ImageSpec? = nil, predictedLost: [String]? = nil,
        predictedLostKeys: [String]? = nil, photosDestination: PhotosDestination? = nil,
        photosFileName: String? = nil, estimatedSavedBytes: Int64? = nil
    ) {
        self.kind = kind
        self.preset = preset
        self.saveTo = saveTo
        self.custom = custom
        self.imageSpec = imageSpec
        self.predictedLost = predictedLost
        self.predictedLostKeys = predictedLostKeys
        self.photosDestination = photosDestination
        self.photosFileName = photosFileName
        self.estimatedSavedBytes = estimatedSavedBytes
    }

    public var isImage: Bool { imageSpec != nil }

    /// Jobs saved before `kind` or `imageSpec` existed decode cleanly with safe defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(ConvertJobKind.self, forKey: .kind) ?? .shrink
        preset = try container.decode(Preset.self, forKey: .preset)
        saveTo = try container.decode(SaveDestination.self, forKey: .saveTo)
        custom = try container.decodeIfPresent(DownscaleSpec.self, forKey: .custom)
        imageSpec = try container.decodeIfPresent(ImageSpec.self, forKey: .imageSpec)
        predictedLost = try container.decodeIfPresent([String].self, forKey: .predictedLost)
        predictedLostKeys = try container.decodeIfPresent([String].self, forKey: .predictedLostKeys)
        photosDestination = try container.decodeIfPresent(PhotosDestination.self, forKey: .photosDestination)
        photosFileName = try container.decodeIfPresent(String.self, forKey: .photosFileName)
        estimatedSavedBytes = try container.decodeIfPresent(Int64.self, forKey: .estimatedSavedBytes)
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
    /// Image conversion on a file.
    public static let imageToolID = "convert-image"
    /// Image / Live Photo conversion on an asset in the Photos library.
    public static let imagePhotosToolID = "convert-image-photos"

    /// The user-facing name. The ids above are what is stored, so renaming this changes no saved job.
    public static let title = "Convert"
    public static let systemImage = "arrow.down.right.and.arrow.up.left"

    public static let descriptor = ToolDescriptor(id: toolID, name: title, symbol: systemImage, category: .video)

    public var id: String { Self.toolID }
    public var title: String { Self.title }
    public var systemImage: String { Self.systemImage }
    public var platforms: ToolPlatforms { [.macOS, .iOS] }
    public var jobKinds: [JobKind] { [Self.fileKind, Self.photosKind, Self.imageFileKind, Self.imagePhotosKind] }

    public static let fileKind = JobKind(rawValue: toolID)
    public static let photosKind = JobKind(rawValue: photosToolID)
    public static let imageFileKind = JobKind(rawValue: imageToolID)
    public static let imagePhotosKind = JobKind(rawValue: imagePhotosToolID)

    public static func isImageJob(_ toolID: String) -> Bool {
        toolID == imageToolID || toolID == imagePhotosToolID
    }

    public static func isPhotosJob(_ toolID: String) -> Bool {
        toolID == photosToolID || toolID == imagePhotosToolID
    }

    public static func isConvertJob(_ toolID: String) -> Bool {
        toolID == toolID || toolID == photosToolID || isImageJob(toolID)
    }

    private let photoStore: any PhotoStore
    private let workFolder: WorkFolder
    private let pendingDeletions: PendingDeletions
    private let originalsBackup: ConvertRunner.BackupProvider
    private let downloadGate = DownloadGate()

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

    /// Videos and images, from files or the Photos library.
    public func accepts(_ input: MediaInput) -> Bool {
        switch input {
        case .file(let url):
            guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .image)
        case .photosAsset:
            return true
        }
    }

    public func runner(for kind: JobKind) -> (any JobRunner)? {
        switch kind {
        case Self.fileKind:
            ConvertRunner(originalsBackup: originalsBackup)
        case Self.imageFileKind:
            ImageConvertRunner(originalsBackup: originalsBackup)
        case Self.photosKind, Self.imagePhotosKind:
            // Photos video and image jobs share one download gate so iCloud transfers never collide.
            PhotosConvertRunner(
                store: photoStore, workFolder: workFolder, pendingDeletions: pendingDeletions,
                core: ConvertRunner(), originalsBackup: originalsBackup, downloads: downloadGate)
        default:
            nil
        }
    }
}
