import AppCore
import Foundation

/// Persists the library as JSON (`library.json`) in a directory, with a security-scoped bookmark per file.
/// The app is not sandboxed, so bookmarks use no options; they exist to follow a file that moved.
public struct BookmarkStore: Sendable {
    /// One stored library file: its identity, where it was, a bookmark to find it again, and what was learned.
    public struct Entry: Codable, Sendable, Equatable {
        public var id: UUID
        public var path: String
        public var bookmark: Data?
        public var byteSize: Int64
        public var inventory: MetadataInventory

        public init(id: UUID, path: String, bookmark: Data?, byteSize: Int64, inventory: MetadataInventory) {
            self.id = id
            self.path = path
            self.bookmark = bookmark
            self.byteSize = byteSize
            self.inventory = inventory
        }
    }

    /// Where an entry's file is now, and a fresh bookmark when the stored one was stale or the file moved.
    public struct Resolved: Sendable {
        public let url: URL
        public let refreshedBookmark: Data?
        /// The file now sits in a Trash folder; callers treat it as gone and keep the original path.
        public let isTrashed: Bool
    }

    public let directory: URL
    public var fileURL: URL { directory.appending(path: "library.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The stored entries; none if nothing was saved yet. An unreadable file is moved to `library.corrupt.json`
    /// (replacing an earlier one) so the next save cannot silently destroy it.
    public func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            let aside = directory.appending(path: "library.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
    }

    public func save(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    /// A bookmark for an existing file, or nil if it cannot be made.
    public static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves the bookmark (which follows a moved file); falls back to the stored path when there is none or it
    /// no longer resolves, as for a deleted file.
    public static func resolve(_ entry: Entry) -> Resolved {
        let stored = URL(filePath: entry.path)
        guard let bookmark = entry.bookmark else {
            return Resolved(url: stored, refreshedBookmark: nil, isTrashed: isInTrash(stored))
        }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return Resolved(url: stored, refreshedBookmark: nil, isTrashed: isInTrash(stored)) }
        if isInTrash(url) { return Resolved(url: stored, refreshedBookmark: nil, isTrashed: true) }
        let moved = url.path != entry.path
        return Resolved(url: url, refreshedBookmark: (stale || moved) ? makeBookmark(for: url) : nil, isTrashed: false)
    }

    /// True for a file inside the user's Trash or any volume's `.Trashes` folder.
    public static func isInTrash(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if resolved.pathComponents.contains(where: { $0 == ".Trashes" || $0 == ".Trash" }) { return true }
        if let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        {
            let prefix = trash.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return resolved.path.hasPrefix(prefix)
        }
        return false
    }
}
