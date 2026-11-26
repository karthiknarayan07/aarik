import Darwin
import Foundation
import UniformTypeIdentifiers
import os

/// Errors thrown when staging an input file into `StagedInputs`.
public enum StagedInputError: Error, Sendable, Equatable {
    /// Refused because the source, staging root, or an intermediate staged folder is a symbolic link.
    case symbolicLinkNotAllowed
    /// Refused because the source is not a regular file (for example, a directory or special file).
    case notARegularFile
    /// File system call failed with an underlying POSIX errno.
    case posix(Int32)
}

/// The app's own copies of videos that reached an action or extension (Share, App Intent). Each copy lives in
/// `<directory>/<uuid>/<name>`. They are ours, never a user's file, so they are removed once their job has ended.
///
/// This folder is separate from the Photos `Work` folder: that one is swept at every launch, this one only keeps
/// what a queued job still needs. Removal is checked to stay strictly inside `directory`, one uuid folder at a time,
/// and symbolic links are never followed.
public struct StagedInputs: Sendable {
    public static let defaultDirectoryName = "Staging"
    public static let defaultChunkSize = 512 * 1024

    public let directory: URL

    /// What staging a mixed batch of URLs did.
    public struct BatchResult: Sendable, Equatable {
        /// The staged file URLs created in `directory`.
        public let staged: [URL]
        /// How many inputs were skipped because they are not videos.
        public let skippedNonVideos: Int
        /// How many video (or symlink) inputs failed to stage.
        public let failed: Int

        public init(staged: [URL], skippedNonVideos: Int, failed: Int) {
            self.staged = staged
            self.skippedNonVideos = skippedNonVideos
            self.failed = failed
        }
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Returns a `StagedInputs` rooted at `<app group container>/<folderName>`, or `nil` when unavailable.
    public static func appGroup(
        identifier: String,
        folderName: String = defaultDirectoryName,
        containerURL: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    ) -> StagedInputs? {
        guard !identifier.isEmpty, let container = containerURL(identifier) else { return nil }
        return StagedInputs(directory: container.appending(path: folderName, directoryHint: .isDirectory))
    }

    /// Resolves the App Group staging store from `bundle`'s `AppGroupIdentifier` Info.plist key, falling back to
    /// `fallbackDirectory` when no group container is available.
    public static func appGroup(
        in bundle: Bundle = .main,
        fallbackDirectory: URL? = nil,
        folderName: String = defaultDirectoryName,
        containerURL: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    ) -> StagedInputs? {
        if let identifier = AppInfo.appGroupIdentifier(in: bundle),
            let store = appGroup(identifier: identifier, folderName: folderName, containerURL: containerURL)
        {
            return store
        }
        return fallbackDirectory.map {
            StagedInputs(directory: $0.appending(path: folderName, directoryHint: .isDirectory))
        }
    }

    /// Whether `typeIdentifier` conforms to `public.movie`.
    public static func isVideoType(_ typeIdentifier: String) -> Bool {
        UTType(typeIdentifier)?.conforms(to: .movie) ?? false
    }

    /// Whether `url` is a regular, non-symlink file whose type conforms to `public.movie`.
    public static func isVideoFile(_ url: URL) -> Bool {
        guard !isSymbolicLink(url), isRegularFile(url) else { return false }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true || values?.isPackage == true { return false }
        if let type = values?.contentType { return type.conforms(to: .movie) }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    /// Writes `data` to a new folder as `name` (its last path component only, so a name can't climb out) and
    /// returns the file. Never overwrites and never follows symlinks. Blocking: call it off the main actor.
    public func stage(name: String, data: Data) throws -> URL {
        guard !Self.isSymbolicLink(directory) else { throw StagedInputError.symbolicLinkNotAllowed }
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !Self.isSymbolicLink(directory), !Self.isSymbolicLink(folder) else {
            throw StagedInputError.symbolicLinkNotAllowed
        }
        let url = folder.appending(path: Self.sanitizedName(name))
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Stream-copies `source` into a new `<directory>/<uuid>/<name>` without loading the file into memory and without
    /// following symbolic links. Writes into a hidden partial sibling first and renames exclusively on completion.
    /// Blocking: call it off the main actor.
    @discardableResult
    public func stage(
        copying source: URL,
        name: String? = nil,
        chunkSize: Int = defaultChunkSize,
        onChunk: ((Int) -> Void)? = nil
    ) throws -> URL {
        guard !Self.isSymbolicLink(directory) else { throw StagedInputError.symbolicLinkNotAllowed }
        guard !Self.isSymbolicLink(source) else { throw StagedInputError.symbolicLinkNotAllowed }

        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            let code = errno
            throw code == ELOOP ? StagedInputError.symbolicLinkNotAllowed : Self.posixError(code)
        }
        defer { Darwin.close(sourceFD) }

        var statBuf = stat()
        guard fstat(sourceFD, &statBuf) == 0 else { throw Self.posixError(errno) }
        guard (statBuf.st_mode & S_IFMT) == S_IFREG else { throw StagedInputError.notARegularFile }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !Self.isSymbolicLink(directory) else { throw StagedInputError.symbolicLinkNotAllowed }

        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        guard !Self.isSymbolicLink(folder) else { throw StagedInputError.symbolicLinkNotAllowed }

        let safeName = Self.sanitizedName(name ?? source.lastPathComponent)
        let finalURL = folder.appending(path: safeName)
        let partialURL = folder.appending(path: ".\(safeName).partial-\(UUID().uuidString)")

        let destFD = Darwin.open(partialURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destFD >= 0 else {
            let code = errno
            removeIfEmpty(folder)
            throw Self.posixError(code)
        }

        var destClosed = false
        var committed = false
        defer {
            if !destClosed { Darwin.close(destFD) }
            if !committed {
                try? FileManager.default.removeItem(at: partialURL)
                removeIfEmpty(folder)
            }
        }

        let effectiveChunkSize = max(1, chunkSize)
        var buffer = [UInt8](repeating: 0, count: effectiveChunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(sourceFD, rawBuffer.baseAddress, effectiveChunkSize)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                let code = errno
                if code == EINTR { continue }
                throw Self.posixError(code)
            }
            onChunk?(bytesRead)
            var writtenTotal = 0
            while writtenTotal < bytesRead {
                let written = buffer.withUnsafeBytes { rawBuffer in
                    let base = rawBuffer.baseAddress!.advanced(by: writtenTotal)
                    return Darwin.write(destFD, base, bytesRead - writtenTotal)
                }
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw Self.posixError(code)
                }
                writtenTotal += written
            }
        }

        if Darwin.close(destFD) != 0 {
            destClosed = true
            throw Self.posixError(errno)
        }
        destClosed = true

        try Self.moveWithoutReplacing(partialURL, to: finalURL)
        committed = true
        return finalURL
    }

    /// Stream-copies every regular movie file in `urls` into `directory`, skipping non-videos with a count and never
    /// following symbolic links. Blocking: call it off the main actor.
    public func stageVideos(from urls: [URL], chunkSize: Int = defaultChunkSize) -> BatchResult {
        var staged: [URL] = []
        var skippedNonVideos = 0
        var failed = 0
        for url in urls {
            if Self.isSymbolicLink(url) {
                failed += 1
                continue
            }
            guard Self.isVideoFile(url) else {
                skippedNonVideos += 1
                continue
            }
            do {
                try staged.append(stage(copying: url, chunkSize: chunkSize))
            } catch {
                failed += 1
            }
        }
        return BatchResult(staged: staged, skippedNonVideos: skippedNonVideos, failed: failed)
    }

    /// Ready staged copies inside `directory`, excluding symbolic links, hidden partial files, and any URL in
    /// `tracked`.
    public func pendingFiles(excluding tracked: Set<URL> = []) -> [URL] {
        guard !Self.isSymbolicLink(directory) else { return [] }
        let trackedPaths = Set(tracked.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var result: [URL] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where UUID(uuidString: child.lastPathComponent) != nil {
            guard !Self.isSymbolicLink(child) else {
                Self.log.notice("Skipped a symbolic link in the staging folder")
                continue
            }
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where Self.isRegularFile(file) && !Self.isSymbolicLink(file) {
                let canonical = file.standardizedFileURL.resolvingSymlinksInPath().path
                if !trackedPaths.contains(canonical) {
                    result.append(file)
                }
            }
        }
        return result
    }

    /// Whether `url` is a copy made here.
    public func owns(_ url: URL) -> Bool { folder(of: url) != nil }

    /// Removes the copy itself, then its folder if that is now empty. Anything else in the folder (a file the app
    /// didn't stage) is left, and so is the folder. A file not made here or any symlink is left alone.
    public func remove(_ url: URL) {
        guard !Self.isSymbolicLink(url), let folder = folder(of: url), !Self.isSymbolicLink(folder) else { return }
        let file = folder.appending(path: url.lastPathComponent)
        guard !Self.isSymbolicLink(file) else { return }
        try? FileManager.default.removeItem(at: file)
        removeIfEmpty(folder)
    }

    /// Removes the copies nothing reads: a folder holding exactly one regular file (the staged copy) that none of
    /// `sources` is in, or an empty folder. A folder holding anything else is left and logged: the app didn't put
    /// it there. A copy a job still needs is kept. Symbolic links are never followed or removed.
    public func sweep(keeping sources: some Sequence<URL>) {
        guard !Self.isSymbolicLink(directory) else {
            Self.log.notice("Skipped sweeping a symbolic link staging directory")
            return
        }
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
            } else if contents.count == 1, Self.isRegularFile(contents[0]), !Self.isSymbolicLink(contents[0]) {
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

    private static func sanitizedName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." ? "Video.mov" : last
    }

    /// Whether `url` itself is a symbolic link (not what it points to).
    public static func isSymbolicLink(_ url: URL) -> Bool {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            return (st.st_mode & S_IFMT) == S_IFLNK
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            return (st.st_mode & S_IFMT) == S_IFREG
        }
        return false
    }

    private static func posixError(_ code: Int32) -> StagedInputError {
        .posix(code)
    }

    private static func moveWithoutReplacing(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw posixError(code) }
        let fd = Darwin.open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw posixError(errno) }
        Darwin.close(fd)
        if rename(source.path, destination.path) != 0 {
            let failure = errno
            try? FileManager.default.removeItem(at: destination)
            throw posixError(failure)
        }
    }

    private func removeIfEmpty(_ folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if contents.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    /// The uuid folder holding `url`, when `url` is a regular non-symlink file directly inside one directly inside
    /// `directory`.
    private func folder(of url: URL) -> URL? {
        guard !Self.isSymbolicLink(directory), !Self.isSymbolicLink(url) else { return nil }
        let rawFolder = url.deletingLastPathComponent()
        guard !Self.isSymbolicLink(rawFolder) else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let folder = url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard folder.deletingLastPathComponent().path == root.path,
            UUID(uuidString: folder.lastPathComponent) != nil
        else { return nil }
        return root.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
    }
}
