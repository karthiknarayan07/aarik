import Foundation

/// Where a library item lives: a file on disk, or a video in the Photos library.
///
/// Only a `.file` item has a file location. Code that opens, reveals, previews, replaces or bookmarks a file asks
/// `LibraryItem.fileURL` and skips an item that has none, so a Photos item never reaches a path-building call.
public enum ItemSource: Sendable, Hashable {
    case file(URL)
    /// The Photos local identifier.
    case photos(String)
}
