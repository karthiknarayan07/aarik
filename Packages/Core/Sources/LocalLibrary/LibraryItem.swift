import AppCore
import CoreGraphics
import Foundation

/// A badge shown on a library item, derived from its metadata inventory.
public enum MediaBadge: String, Sendable, CaseIterable, Hashable {
    case dolbyVision
    case hdr
    case k4 = "4K"
    case cinematic
    case sloMo
    case spatial
    case livePhoto
    case portrait
    case raw
    case animated
    case transparent
    case edited
    case sdr
}

/// One media file (video or image) in the library.
public struct LibraryItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let mediaKind: MediaKind
    /// Where the item is. Use `fileURL` for a file path; a Photos item has none.
    public let source: ItemSource
    /// The name shown for the item: the file's name, or the original file name Photos has for it.
    public let name: String
    public let byteSize: Int64
    /// Seconds (0 for still/animated images).
    public let duration: Double
    /// Size as displayed, so a clip or photo taken in portrait is taller than wide.
    public let pixelSize: CGSize
    public let frameRate: Double
    public let captureDate: Date?
    public let badges: Set<MediaBadge>
    public var isAvailable: Bool
    public let inventory: MetadataInventory
    /// When a Photos item last changed there (an edit changes it); nil for a file or when unknown.
    public let modifiedDate: Date?

    public init(
        id: UUID, mediaKind: MediaKind = .video, source: ItemSource, name: String, byteSize: Int64,
        duration: Double = 0, pixelSize: CGSize, frameRate: Double = 0, captureDate: Date?,
        badges: Set<MediaBadge>, isAvailable: Bool, inventory: MetadataInventory, modifiedDate: Date? = nil
    ) {
        self.id = id
        self.mediaKind = mediaKind
        self.source = source
        self.name = name
        self.byteSize = byteSize
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.captureDate = captureDate
        self.badges = badges
        self.isAvailable = isAvailable
        self.inventory = inventory
        self.modifiedDate = modifiedDate
    }

    /// A file item named after the file.
    public init(
        id: UUID, mediaKind: MediaKind = .video, url: URL, byteSize: Int64, duration: Double = 0,
        pixelSize: CGSize, frameRate: Double = 0, captureDate: Date?, badges: Set<MediaBadge>,
        isAvailable: Bool, inventory: MetadataInventory
    ) {
        self.init(
            id: id, mediaKind: mediaKind, source: .file(url), name: url.lastPathComponent, byteSize: byteSize,
            duration: duration, pixelSize: pixelSize, frameRate: frameRate, captureDate: captureDate,
            badges: badges, isAvailable: isAvailable, inventory: inventory)
    }

    public var isImage: Bool { mediaKind == .image }
    public var isVideo: Bool { mediaKind == .video }
    public var megapixels: Double { (pixelSize.width * pixelSize.height) / 1_000_000.0 }

    /// The file's location, or nil for an item that isn't a file (a Photos item).
    public var fileURL: URL? {
        if case .file(let url) = source { url } else { nil }
    }

    /// The Photos local identifier, or nil for a file.
    public var photosIdentifier: String? {
        if case .photos(let identifier) = source { identifier } else { nil }
    }

    /// Every field counts, so a view showing an item redraws when it changes (it went missing, or a Replace
    /// shrank it).
    public static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        lhs.id == rhs.id && lhs.mediaKind == rhs.mediaKind && lhs.isAvailable == rhs.isAvailable
            && lhs.byteSize == rhs.byteSize && lhs.source == rhs.source && lhs.name == rhs.name
            && lhs.badges == rhs.badges && lhs.duration == rhs.duration && lhs.pixelSize == rhs.pixelSize
            && lhs.frameRate == rhs.frameRate && lhs.captureDate == rhs.captureDate
            && lhs.inventory == rhs.inventory && lhs.modifiedDate == rhs.modifiedDate
    }

    /// By id only, which agrees with `==` (equal items share their id).
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
