import AppCore
import Foundation
import MediaEngine
import UniformTypeIdentifiers

/// A file the scanner inspected, with the bookmark made for it.
public struct ScannedFile: Sendable {
    public let item: LibraryItem
    public let bookmark: Data?
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

    /// Inspects one movie file off the caller's actor; nil if it can't be read as a video.
    @concurrent
    nonisolated static func inspectFile(_ url: URL, inspector: MediaInspector = MediaInspector()) async
        -> ScannedFile?
    {
        guard let inventory = try? await inspector.inventory(of: url),
            let size = fileSize(url),
            let item = LibraryItemBuilder.build(url: url, inventory: inventory, byteSize: size)
        else { return nil }
        return ScannedFile(item: item, bookmark: BookmarkStore.makeBookmark(for: url))
    }

    /// The file's size read from the file system, never from URL resource values: those can stay cached for a path
    /// after a Replace swapped the file there, which made the library keep showing the original's size.
    nonisolated static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Movie files at or below `urls`, in path order within each folder.
    private nonisolated static func movieFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.contentTypeKey, .isDirectoryKey, .isPackageKey, .isHiddenKey]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, values.isPackage != true {
                let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                guard
                    let walker = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: keys, options: options)
                else { continue }
                var found: [URL] = []
                while let next = walker.nextObject() as? URL {
                    if isMovie(next) { found.append(next) }
                }
                result += found.sorted { $0.path < $1.path }
            } else if values.isHidden != true, isMovie(url) {
                result.append(url)
            }
        }
        return result
    }

    private nonisolated static func isMovie(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey]),
            values.isDirectory != true, values.isPackage != true
        else { return false }
        return values.contentType?.conforms(to: .movie) ?? false
    }
}
