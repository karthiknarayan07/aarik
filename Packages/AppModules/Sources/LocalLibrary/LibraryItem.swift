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
    case edited
    case sdr
}

/// One movie file in the library.
public struct LibraryItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let byteSize: Int64
    /// Seconds.
    public let duration: Double
    /// Size as displayed, so a clip recorded in portrait is taller than wide.
    public let pixelSize: CGSize
    public let frameRate: Double
    public let captureDate: Date?
    public let badges: Set<MediaBadge>
    public var isAvailable: Bool
    public let inventory: MetadataInventory

    public init(
        id: UUID, url: URL, byteSize: Int64, duration: Double, pixelSize: CGSize, frameRate: Double,
        captureDate: Date?, badges: Set<MediaBadge>, isAvailable: Bool, inventory: MetadataInventory
    ) {
        self.id = id
        self.url = url
        self.byteSize = byteSize
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.captureDate = captureDate
        self.badges = badges
        self.isAvailable = isAvailable
        self.inventory = inventory
    }

    /// Every field counts, so a view showing an item redraws when it changes (it went missing, or a Replace
    /// shrank it).
    public static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        lhs.id == rhs.id && lhs.isAvailable == rhs.isAvailable && lhs.byteSize == rhs.byteSize && lhs.url == rhs.url
            && lhs.badges == rhs.badges && lhs.duration == rhs.duration && lhs.pixelSize == rhs.pixelSize
            && lhs.frameRate == rhs.frameRate && lhs.captureDate == rhs.captureDate && lhs.inventory == rhs.inventory
    }

    /// By id only, which agrees with `==` (equal items share their id).
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
