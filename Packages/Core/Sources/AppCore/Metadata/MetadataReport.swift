/// A metadata item whose value differs between source and output.
public struct MetadataChange: Hashable, Codable, Sendable {
    public let key: String
    public let displayName: String
    public let from: String
    public let to: String

    public init(key: String, displayName: String, from: String, to: String) {
        self.key = key
        self.displayName = displayName
        self.from = from
        self.to = to
    }
}

/// What a conversion kept, changed or lost, relative to the source.
public struct MetadataReport: Codable, Sendable, Equatable {
    public var kept: [MetadataItem]
    public var changed: [MetadataChange]
    public var lost: [MetadataItem]

    public init(
        kept: [MetadataItem] = [], changed: [MetadataChange] = [], lost: [MetadataItem] = []
    ) {
        self.kept = kept
        self.changed = changed
        self.lost = lost
    }

    public var isLossless: Bool { lost.isEmpty }
}
