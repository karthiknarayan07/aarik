import Foundation

/// Whether an item or input is a video or an image.
public enum MediaKind: String, Codable, Sendable, Hashable, CaseIterable {
    case video
    case image
}
