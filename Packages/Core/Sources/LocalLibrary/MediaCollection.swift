import Foundation

/// What the grid's browser reads: a collection of videos that changes over time. `LocalLibrary` and the Photos
/// library both conform.
@MainActor
public protocol MediaCollection: AnyObject {
    var items: [LibraryItem] { get }
    /// Changes whenever `items` does, so caches can tell cheaply that the collection changed.
    var revision: Int { get }
    var isScanning: Bool { get }
}

extension LocalLibrary: MediaCollection {}
