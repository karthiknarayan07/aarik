import Foundation

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

    /// Removes the copy and its folder. Anything not made here is left alone.
    public func remove(_ url: URL) {
        guard let folder = folder(of: url) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every copy whose folder none of `sources` is in: what a crash or an early quit left behind. A copy a
    /// queued or running job still reads is kept.
    public func sweep(keeping sources: some Sequence<URL>) {
        let kept = Set(sources.compactMap { folder(of: $0)?.path })
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            guard !kept.contains(child.resolvingSymlinksInPath().path) else { continue }
            try? FileManager.default.removeItem(at: child)
        }
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
