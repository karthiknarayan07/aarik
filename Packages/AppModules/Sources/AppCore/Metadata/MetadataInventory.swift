/// The ordered list of metadata items found in a media file.
public struct MetadataInventory: Codable, Sendable, Equatable {
    public var items: [MetadataItem]

    public init(items: [MetadataItem] = []) {
        self.items = items
    }

    /// The first item with the given key, if any.
    public subscript(key: String) -> MetadataItem? {
        items.first { $0.key == key }
    }
}
