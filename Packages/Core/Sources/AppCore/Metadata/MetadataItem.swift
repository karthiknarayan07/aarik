/// Broad grouping used to organise metadata in the UI.
public enum MetadataCategory: String, Codable, Sendable, CaseIterable {
    case camera, location, date, video, hdr, audio, timedMetadata, track, fileSystem, other
}

/// One comparable piece of metadata about a media file.
public struct MetadataItem: Hashable, Codable, Sendable {
    /// Stable, namespaced identifier (for example `qt.com.apple.quicktime.make`).
    public let key: String
    public let category: MetadataCategory
    /// Sentence-case, user-facing name.
    public let displayName: String
    /// Normalized, comparable value.
    public let value: String

    public init(key: String, category: MetadataCategory, displayName: String, value: String) {
        self.key = key
        self.category = category
        self.displayName = displayName
        self.value = value
    }
}
