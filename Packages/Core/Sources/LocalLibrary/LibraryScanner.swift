import AppCore
import Foundation
import MediaEngine
import UniformTypeIdentifiers

/// A file the scanner inspected, with the bookmark made for it and its modification date when it was read.
public struct ScannedFile: Sendable {
    public let item: LibraryItem
    public let bookmark: Data?
    public var modifiedAt: Date?
}

/// A file's size and modification date, read from the file system: together they tell that a file changed.
struct FileStamp: Sendable, Equatable {
    let size: Int64
    let modified: Date?

    /// Never from URL resource values: those can stay cached for a path after a Replace swapped the file there,
    /// which made the library keep showing the original's size.
    static func read(_ url: URL) -> FileStamp? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        return FileStamp(size: size, modified: attributes[.modificationDate] as? Date)
    }

    /// Whether this stamp still describes a file stored with `size` and `modified`. Dates within a millisecond
    /// are the same (they go through JSON).
    func matches(size: Int64, modified: Date?) -> Bool {
        guard size == self.size else { return false }
        switch (modified, self.modified) {
        case (nil, nil): return true
        case (let stored?, let current?): return abs(stored.timeIntervalSince(current)) < 0.001
        default: return false
        }
    }
}

/// Finds movie files in files and folders and inspects them off the main actor.
public actor LibraryScanner {
    private let inspector: MediaInspector

    public init(inspector: MediaInspector = MediaInspector()) {
        self.inspector = inspector
    }

    /// The comparison key for a file: its standardized path with symlinks resolved.
    public nonisolated static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Inspects every movie under `urls` (folders recursively; hidden files and packages skipped), skipping paths
    /// in `known`. Calls `onBatch` with batches of at most `batchSize` files as they fill, and with the remainder at
    /// the end. Cancelling the calling task stops the scan after the file in progress; what was inspected so far
    /// is still delivered. Files that cannot be inspected are skipped. Nothing is written to the files.
    public func scan(
        _ urls: [URL], excluding known: Set<String> = [], batchSize: Int = 50,
        onBatch: @Sendable ([ScannedFile]) async -> Void
    ) async {
        let size = max(1, batchSize)
        var seen = known
        var batch: [ScannedFile] = []
        for url in Self.movieFiles(in: urls) {
            if Task.isCancelled { break }
            guard seen.insert(Self.pathKey(url)).inserted else { continue }
            guard let file = await inspect(url) else { continue }
            batch.append(file)
            if batch.count >= size {
                await onBatch(batch)
                batch = []
            }
        }
        if !batch.isEmpty { await onBatch(batch) }
    }

    private func inspect(_ url: URL) async -> ScannedFile? {
        await Self.inspectFile(url, inspector: inspector)
    }

    /// Inspects one media file (movie or image) off the caller's actor; nil if unreadable.
    @concurrent
    nonisolated static func inspectFile(_ url: URL, inspector: MediaInspector = MediaInspector()) async
        -> ScannedFile?
    {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let isMovie = Self.isMovie(url)
        let isImage = !isMovie && Self.isImage(url)
        guard isMovie || isImage, let stamp = FileStamp.read(url) else { return nil }

        let inventory: MetadataInventory?
        if isMovie {
            inventory = try? await inspector.inventory(of: url)
        } else {
            inventory = try? ImageInspector().inventory(of: url)
        }
        guard let inventory,
            let item = LibraryItemBuilder.build(url: url, inventory: inventory, byteSize: stamp.size)
        else { return nil }
        return ScannedFile(item: item, bookmark: BookmarkStore.makeBookmark(for: url), modifiedAt: stamp.modified)
    }

    /// Movie and image files at or below `urls`, in path order within each folder.
    private nonisolated static func movieFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.contentTypeKey, .isDirectoryKey, .isPackageKey, .isHiddenKey]
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, values.isPackage != true {
                let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                guard
                    let walker = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: keys, options: options)
                else { continue }
                var found: [URL] = []
                while let next = walker.nextObject() as? URL {
                    if isSupportedMedia(next) { found.append(next) }
                }
                result += found.sorted { $0.path < $1.path }
            } else if values.isHidden != true, isSupportedMedia(url) {
                result.append(url)
            }
        }
        return result
    }

    private nonisolated static func isSupportedMedia(_ url: URL) -> Bool {
        isMovie(url) || isImage(url)
    }

    private nonisolated static func isMovie(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey]),
            values.isDirectory != true, values.isPackage != true
        else { return false }
        return values.contentType?.conforms(to: .movie) ?? false
    }

    private nonisolated static func isImage(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey]),
            values.isDirectory != true, values.isPackage != true
        else { return false }
        return values.contentType?.conforms(to: .image) ?? false
    }
}
