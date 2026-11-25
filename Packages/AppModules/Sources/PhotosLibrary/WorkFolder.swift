import Foundation

/// The app's scratch space for Photos jobs: `<Application Support>/<bundle id>/Work/<job id>/`.
///
/// Photos input is written here before it is converted. Nothing else is ever written or deleted through this type:
/// every removal is checked to be inside the `Work` folder, and never the folder itself. The runner calls
/// `remove(jobID:)` on every exit path (done, failed, cancelled); `sweep()` clears what a crash or quit left behind
/// and runs at launch, when no job can be using it.
public struct WorkFolder: Sendable {
    /// The `Work` folder itself.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<Application Support>/<bundle id>/Work`. The folder is not created until a job needs it.
    public static func standard(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> WorkFolder {
        let support =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL.applicationSupportDirectory
        return WorkFolder(
            root: support.appending(path: bundleIdentifier ?? "App", directoryHint: .isDirectory)
                .appending(path: "Work", directoryHint: .isDirectory))
    }

    /// The folder for one job.
    public func url(for jobID: UUID) -> URL {
        root.appending(path: jobID.uuidString, directoryHint: .isDirectory)
    }

    /// Creates (if needed) and returns the folder for one job.
    @discardableResult
    public func create(for jobID: UUID) throws -> URL {
        let folder = url(for: jobID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes one job's folder and everything in it. Safe to call when it doesn't exist or twice.
    public func remove(jobID: UUID) {
        remove(url(for: jobID))
    }

    /// Removes `url` when it is inside the work folder; anything else (including the work folder itself) is left
    /// alone.
    public func remove(_ url: URL) {
        guard contains(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes everything inside the work folder (not the folder itself). For launch, before any job runs.
    public func sweep() {
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        for child in children { remove(child) }
    }

    /// True when `url` is strictly inside the work folder, after resolving `..` and symbolic links.
    func contains(_ url: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return target.count > base.count && Array(target.prefix(base.count)) == base
    }
}
