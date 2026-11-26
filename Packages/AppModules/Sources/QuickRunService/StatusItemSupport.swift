import AppKit
import Foundation
import UniformTypeIdentifiers

extension MovieDropFilter {
    /// A guess from the file name alone, with no disk access: whether this looks like a movie. Used while a drag is
    /// over the status item, where touching the disk for every file would stall the main thread.
    public static func looksLikeMovie(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath,
            let type = UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .movie)
    }

    /// Whether any of `urls` looks like a movie (see `looksLikeMovie`). A file whose name says nothing (no extension,
    /// or one the system doesn't know) falls back to `contentType`, which reads the disk; at most `maxLookups`
    /// files are looked up, so a drag of thousands of unnamed files stays quick. Call this once per drag (see
    /// `DragVerdictCache`), not for every update of the pointer.
    public static func mightContainMovie(
        _ urls: [URL], maxLookups: Int = 20, contentType: (URL) -> UTType? = diskContentType
    ) -> Bool {
        var lookups = 0
        for url in urls {
            if looksLikeMovie(url) { return true }
            guard url.isFileURL, !url.hasDirectoryPath, UTType(filenameExtension: url.pathExtension) == nil,
                lookups < maxLookups
            else { continue }
            lookups += 1
            if contentType(url)?.conforms(to: .movie) == true { return true }
        }
        return false
    }

    /// The type the disk gives a file; nil for a folder, a package or an unreadable file.
    public static func diskContentType(of url: URL) -> UTType? {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey]),
            values.isDirectory != true, values.isPackage != true
        else { return nil }
        return values.contentType
    }

    /// Whether a drag whose items advertise these type identifiers (one list per item, as a drop target sees them
    /// without reading any file) might hold a movie. An item counts when one of its types is a movie, or when it
    /// names no real content type (only a file address, say), because then nothing says it isn't one. A folder, an
    /// image or a document names its type and is refused.
    public static func providersMightHoldMovie(_ typeIdentifiers: [[String]]) -> Bool {
        typeIdentifiers.contains { identifiers in
            let types = identifiers.compactMap { UTType($0) }
            if types.contains(where: { $0.conforms(to: .movie) }) { return true }
            let uninformative: [UTType] = [.fileURL, .url, .item, .data, .content]
            return types.allSatisfy { type in type.isDynamic || uninformative.contains(type) }
        }
    }

    /// Splits `urls` into the movies and everything else (folders, packages, unreadable files, other types). Reads
    /// the disk, so call it off the main thread.
    public static func partition(_ urls: [URL]) -> (movies: [URL], others: [URL]) {
        let movies = movies(in: urls)
        let kept = Set(movies.map(\.absoluteString))
        return (movies, urls.filter { !kept.contains($0.absoluteString) })
    }

    /// The file URLs on a pasteboard, read without checking the files.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// The answer for one drag session, worked out once when the drag enters and reused for every later update.
public struct DragVerdictCache: Sendable, Equatable {
    private var sequence: Int?
    private var verdict = false

    public init() {}

    /// The verdict for the drag session `sequence`, computing it only the first time that session is asked about.
    public mutating func verdict(forSession sequence: Int, compute: () -> Bool) -> Bool {
        if self.sequence != sequence {
            self.sequence = sequence
            verdict = compute()
        }
        return verdict
    }

    /// Forgets the session, so the next drag is judged afresh.
    public mutating func reset() {
        sequence = nil
        verdict = false
    }
}

/// Whether opening the popover should activate the app. A pointer click leaves the app and the windows in front
/// alone, like Apple's menu bar extras; opening it from the keyboard activates, because an inactive app's popover
/// can't take keystrokes. With VoiceOver on it always activates: VoiceOver presses the button with a mouse-like
/// event, and its cursor can only move into the popover once the app is active.
public enum PopoverActivation {
    public static func shouldActivate(openedBy eventType: NSEvent.EventType?, voiceOverEnabled: Bool) -> Bool {
        voiceOverEnabled || !StatusItemHitTest.passesThrough(eventType)
    }
}
