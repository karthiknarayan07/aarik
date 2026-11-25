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

    public static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
