import AppCore
import Foundation
import os

/// The app's own copies of videos that reached an action as data only (no file to point at). Each copy lives in
/// `<directory>/<uuid>/<name>`. They are ours, never a user's file, so they are removed once their job has ended.
///
/// This folder is separate from the Photos `Work` folder: that one is swept at every launch, this one only keeps
/// what a queued job still needs. Removal is checked to stay strictly inside `directory`, one uuid folder at a time.
public struct StagedInputs: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes `data` to a new folder as `name` (its last path component only, so a name can't climb out) and
    /// returns the file. Never overwrites. Blocking: call it off the main actor.
    public func stage(name: String, data: Data) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let last = (name as NSString).lastPathComponent
        let url = folder.appending(path: last.isEmpty || last == "." || last == ".." ? "Video.mov" : last)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Whether `url` is a copy made here.
    public func owns(_ url: URL) -> Bool { folder(of: url) != nil }

    /// Removes the copy itself, then its folder if that is now empty. Anything else in the folder (a file the app
    /// didn't stage) is left, and so is the folder. A file not made here is left alone.
    public func remove(_ url: URL) {
        guard let folder = folder(of: url), !Self.isSymbolicLink(folder) else { return }
        let file = folder.appending(path: url.lastPathComponent)
        try? FileManager.default.removeItem(at: file)
        removeIfEmpty(folder)
    }

    /// Removes the copies nothing reads: a folder holding exactly one regular file (the staged copy) that none of
    /// `sources` is in, or an empty folder. A folder holding anything else is left and logged: the app didn't put
    /// it there. A copy a job still needs is kept.
    public func sweep(keeping sources: some Sequence<URL>) {
        let kept = Set(sources.compactMap { folder(of: $0)?.path })
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            if Self.isSymbolicLink(child) {
                Self.log.notice("Skipped a symbolic link in the staging folder")
                continue
            }
            guard !kept.contains(child.resolvingSymlinksInPath().path) else { continue }
            let contents =
                (try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: child)
            } else if contents.count == 1, Self.isRegularFile(contents[0]) {
                try? FileManager.default.removeItem(at: contents[0])
                removeIfEmpty(child)
            } else {
                Self.log.notice("Left a staging folder that holds more than its copy")
            }
        }
    }

    /// Whether a job in this state still needs its copy: it is waiting or running, or it failed and may be retried.
    /// A finished, kept-as-is or removed job doesn't.
    public static func isNeeded(by job: Job) -> Bool {
        switch job.state {
        case .queued, .running, .failed: true
        case .completed, .keptAsIs: false
        }
    }

    /// Removes the watched copies no job in `jobs` needs and returns the ones still watched. A job gone from the
    /// list (cancelled, or a failed one removed) needs nothing.
    public func release(watching copies: Set<URL>, jobs: [Job]) -> Set<URL> {
        let needed = Set(jobs.filter(Self.isNeeded(by:)).map { $0.source.standardizedFileURL })
        var remaining = copies
        for copy in copies where !needed.contains(copy.standardizedFileURL) {
            remove(copy)
            remaining.remove(copy)
        }
        return remaining
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app", category: "staging")

    /// Whether `url` itself is a symbolic link (not what it points to).
    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    private func removeIfEmpty(_ folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if contents.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    /// The uuid folder holding `url`, when `url` is a file directly inside one directly inside `directory`.
    private func folder(of url: URL) -> URL? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let folder = url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard folder.deletingLastPathComponent().path == root.path,
            UUID(uuidString: folder.lastPathComponent) != nil
        else { return nil }
        return root.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
    }
}
