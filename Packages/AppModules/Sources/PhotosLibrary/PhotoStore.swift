import CoreGraphics
import Foundation

/// Where a video was taken.
public struct PhotoLocation: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double
    /// Meters above sea level.
    public let altitude: Double

    public init(latitude: Double, longitude: Double, altitude: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// The video kinds Photos records for an asset.
public struct PhotoSubtypes: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Slo-mo.
    public static let highFrameRate = PhotoSubtypes(rawValue: 1 << 0)
    public static let cinematic = PhotoSubtypes(rawValue: 1 << 1)
    /// Spatial video (two views).
    public static let spatial = PhotoSubtypes(rawValue: 1 << 2)
    public static let timelapse = PhotoSubtypes(rawValue: 1 << 3)
    public static let streamed = PhotoSubtypes(rawValue: 1 << 4)
}

/// One video in the Photos library, read from its metadata only (nothing is downloaded).
public struct PhotoAsset: Sendable, Hashable, Identifiable {
    /// The Photos local identifier.
    public let id: String
    public let creationDate: Date?
    public let location: PhotoLocation?
    /// Size as displayed.
    public let pixelSize: CGSize
    /// Seconds.
    public let duration: Double
    public let isFavorite: Bool
    public let isHidden: Bool
    /// True when the video was edited in Photos.
    public let hasAdjustments: Bool
    public let subtypes: PhotoSubtypes
    public let originalFileName: String
    /// Size of the original video resource; nil when Photos doesn't say.
    public let originalByteSize: Int64?
    /// Whether the original is on this Mac (false when only in iCloud); nil when Photos doesn't say.
    public let isLocallyAvailable: Bool?
    /// When the asset last changed in Photos (an edit changes it); nil when Photos doesn't say.
    public let modificationDate: Date?

    public init(
        id: String, creationDate: Date? = nil, location: PhotoLocation? = nil, pixelSize: CGSize,
        duration: Double, isFavorite: Bool = false, isHidden: Bool = false, hasAdjustments: Bool = false,
        subtypes: PhotoSubtypes = [], originalFileName: String, originalByteSize: Int64? = nil,
        isLocallyAvailable: Bool? = nil, modificationDate: Date? = nil
    ) {
        self.id = id
        self.creationDate = creationDate
        self.location = location
        self.pixelSize = pixelSize
        self.duration = duration
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.hasAdjustments = hasAdjustments
        self.subtypes = subtypes
        self.originalFileName = originalFileName
        self.originalByteSize = originalByteSize
        self.isLocallyAvailable = isLocallyAvailable
        self.modificationDate = modificationDate
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(pixelSize.width)
        hasher.combine(pixelSize.height)
        hasher.combine(duration)
        hasher.combine(originalByteSize)
    }
}

/// The user's answer to the Photos access request.
public enum PhotoAuthorization: Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    /// Access to the photos the user picked only.
    case limited
    case authorized

    /// True when the library (or the picked part of it) can be read.
    public var allowsReading: Bool { self == .authorized || self == .limited }
}

public enum PhotoStoreError: Error, Sendable, Equatable, LocalizedError {
    case notAuthorized
    /// The asset with this local identifier is gone.
    case notInLibrary(String)
    /// The video had to come from iCloud and could not (offline, refused, or the download failed). The text is
    /// what PhotoKit said.
    case downloadFailed(String)
    /// Photos has no video to give for the asset, or the export failed; the text says why.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: "Access to your Photos library isn't allowed."
        case .notInLibrary: "No longer in your Photos library"
        case .downloadFailed: "Couldn't download from iCloud. Check that you're online and try again."
        case .unavailable(let reason): "Photos couldn't provide this video: \(reason)"
        }
    }
}

/// Where a Photos input fetch is. Downloading from iCloud is its own phase: it is usually the longest part (a
/// clip is fetched at network speed and exported in a fraction of a second), so it gets its own progress rather
/// than a slice of the job's.
public enum FetchProgress: Sendable, Equatable {
    /// Bringing the video from iCloud (or, when it is on this Mac, copying it out), 0 to 1.
    case downloading(Double)
    /// Rendering an edited video's current version into the work folder, 0 to 1.
    case exporting(Double)

    public var fraction: Double {
        switch self {
        case .downloading(let value), .exporting(let value): value
        }
    }
}

/// Read access to the Photos library. The real one wraps PhotoKit; tests use `FakePhotoStore`.
public protocol PhotoStore: Sendable {
    func authorization() async -> PhotoAuthorization
    /// Asks for read and write access, showing the system prompt the first time.
    func requestAuthorization() async -> PhotoAuthorization
    /// Every video in the library, newest first. Never downloads from iCloud.
    func videos() async throws -> [PhotoAsset]
    /// Yields when the library changed; callers refetch (diffing is the caller's job).
    func changes() -> AsyncStream<Void>
    /// Local identifiers of the user albums that contain the asset.
    func albums(containing id: String) async throws -> [String]
    /// A thumbnail from what is on this Mac, or nil. Never downloads from iCloud.
    func thumbnail(for id: String, size: CGSize) async -> CGImage?
    /// The asset's current metadata (including whether it was edited); throws `notInLibrary` when it is gone.
    func asset(id: String) async throws -> PhotoAsset
    /// Writes the asset's original video resource to `url`, downloading from iCloud when needed and reporting
    /// `.downloading` progress. Cancelling the task stops the transfer.
    func writeOriginal(id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void) async throws
    /// Writes the current (edited) version to `url` as a passthrough export, downloading from iCloud when needed:
    /// `.downloading` progress first, then `.exporting`. Cancelling the task stops it.
    func exportCurrentVersion(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws
}
