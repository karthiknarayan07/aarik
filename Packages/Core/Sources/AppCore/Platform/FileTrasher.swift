import Foundation

/// Moves a file somewhere the user can get it back: the Trash on the Mac, and the app's recoverable location on iOS.
/// Photos assets are different: their "Recently Deleted" goes through `PhotoStore` and the system's confirmation, never
/// through this seam. Tests use `FakeTrasher` (MediaTestSupport).
public protocol FileTrasher: Sendable {
    /// Returns where the item ended up.
    func moveToTrash(_ url: URL) throws -> URL
}

/// `FileManager.trashItem`. On iOS it throws for files outside a Files-managed location, which is why Replace there
/// only ever deletes Photos originals (Recently Deleted).
public struct SystemFileTrasher: FileTrasher {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }
}
