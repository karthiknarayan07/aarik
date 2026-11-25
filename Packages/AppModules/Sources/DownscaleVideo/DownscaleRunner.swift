import AppCore
import Foundation
import MediaEngine

public enum DownscaleRunnerError: Error, LocalizedError, Equatable {
    case sourceUnavailable
    case outputFolderUnavailable
    case nameTaken

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "Original file is missing or the drive isn't connected"
        case .outputFolderUnavailable: "The chosen output folder is missing or the drive isn't connected"
        case .nameTaken: "Couldn't find a free output name"
        }
    }
}

public struct DownscaleRunner: JobRunner {
    /// Moves a file to the Trash and returns where it went.
    public typealias Trasher = @Sendable (URL) throws -> URL
    /// Read when a Replace is about to trash an original: the folder to copy it to first, or nil for no copy.
    public typealias BackupProvider = @Sendable () -> OriginalsBackup?
    typealias Sizer = @Sendable (URL) throws -> Int64
    typealias Inspector = @Sendable (URL) async throws -> MetadataInventory

    static let maxNamingAttempts = 3
    private let trash: Trasher
    private let inspect: Inspector
    let sizeOf: Sizer
    private let originalsBackup: BackupProvider

    /// `originalsBackup` is asked at the moment of each Replace, so a setting changed while the queue runs applies
    /// to the next Replace without rebuilding the runner or the queue.
    public init(originalsBackup: @escaping BackupProvider = { nil }) {
        self.init(trash: Self.trashItem, originalsBackup: originalsBackup)
    }

    /// Seams for tests: `trash` reports the Trash location of the fixture a test created, `inspect` reads the
    /// output's metadata (a test can make the output look unfaithful), `sizeOf` measures the output and the backup
    /// copy.
    init(
        trash: @escaping Trasher,
        inspect: @escaping Inspector = { try await MediaInspector().inventory(of: $0) },
        sizeOf: @escaping Sizer = { try DownscaleRunner.fileSize($0) },
        originalsBackup: @escaping BackupProvider = { nil }
    ) {
        self.sizeOf = sizeOf
        self.trash = trash
        self.inspect = inspect
        self.originalsBackup = originalsBackup
    }

    private static func trashItem(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    public func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        let settings = try JSONDecoder().decode(DownscaleJobSettings.self, from: job.settings)
        let source = try Self.resolveSource(job)
        // What the original is now; a Replace goes ahead only if it is still the same file at the end.
        let identity = try FileIdentity(of: source)
        let byteSize = identity.size
        let inventory = try await MediaInspector().inventory(of: source)

        // Presets and custom specs go through the same planner: spatial check, Already small, 10% rule. The
        // planner's spec is the one encoded and verified (a slo-mo clip's frame-rate cap is dropped there).
        let requested = settings.custom ?? settings.preset.spec(for: inventory, byteSize: byteSize)
        let spec: DownscaleSpec
        let predicted: MetadataReport
        switch DownscalePlanner.decide(inventory: inventory, byteSize: byteSize, spec: requested) {
        case .keptAsIs(let reason): return .keptAsIs(reason: reason)
        case .convert(let planned, _, let report): (spec, predicted) = (planned, report)
        }

        let folder = try Self.outputFolder(for: settings.saveTo, source: source)
        defer { folder.stop() }
        let label = Self.label(for: spec, settings: settings)
        let pathExtension = try await OutputContainer.pathExtension(forSource: source)

        let output: URL
        do {
            output = try await encode(
                source: source, spec: spec, label: label, directory: folder.url, pathExtension: pathExtension,
                progress: progress)
        } catch DownscaleError.sourceAlreadySmall {
            return .keptAsIs(reason: "Already small")
        }
        // Cancelled once the output exists: remove it (it is ours) and leave the original alone.
        try Self.stopIfCancelled(removing: output)

        // The estimate can overstate the saving (heavy audio counted as video). If the real output is not at least
        // 10% smaller, remove our own output and keep the original untouched.
        let outputSize = try sizeOf(output)
        if outputSize >= byteSize * 9 / 10 {
            try? FileManager.default.removeItem(at: output)
            return .keptAsIs(reason: "Would save less than 10%")
        }

        let outputInventory = try await inspect(output)
        try Self.stopIfCancelled(removing: output)
        let report = MetadataDiff.report(source: inventory, output: outputInventory)
        var warnings = Self.warnings(report, predicted: predicted, spec: spec)

        var finalURL = output
        var replaced = false
        if settings.saveTo == .replace {
            // Only a verified output replaces the original, only once its backup (when that is on) is written and
            // checked, and only once the original is safely in the Trash. Otherwise nothing moves and the job
            // still completes with the output beside the original.
            if !warnings.isEmpty {
                warnings.append(Self.keptBecause("the copy couldn't be verified"))
            } else {
                let result = replace(source, identity: identity, with: output)
                finalURL = result.url
                replaced = result.warning == nil
                if let warning = result.warning { warnings.append(warning) }
            }
        }
        return .completed(
            JobOutcome(
                output: finalURL, bytesBefore: byteSize, bytesAfter: outputSize,
                report: report, replacedOriginal: replaced, warnings: warnings))
    }

    // MARK: - Replace

    /// Backs the original up when asked to, trashes it, and gives the output the original's name (with the
    /// output's extension, when the container changed) if that is still free. The original must still be the
    /// file the conversion read. Returns where the output ends up, and the warning saying why the original was
    /// kept when it was.
    private func replace(_ source: URL, identity: FileIdentity, with output: URL) -> (url: URL, warning: String?) {
        guard identity.matches(source) else { return (output, Self.originalChanged) }
        if let backup = originalsBackup() {
            do {
                _ = try backUp(source, byteSize: identity.size, into: backup.folder)
            } catch {
                return (output, Self.keptBecause(error.keptBecause))
            }
        }
        guard identity.matches(source) else { return (output, Self.originalChanged) }
        guard (try? trash(source)) != nil else {
            return (output, Self.keptBecause("it couldn't be moved to the Trash"))
        }
        // Take the original's name if it is still free, else keep the output's own name.
        let target = Self.replacementURL(for: source, output: output)
        if (try? AtomicOutput.moveWithoutReplacing(output, to: target)) != nil { return (target, nil) }
        return (output, nil)
    }

    /// The original's path, with the output's extension when the output is in another container
    /// (`IMG_1.mp4` replaced by a QuickTime file becomes `IMG_1.mov`).
    static func replacementURL(for source: URL, output: URL) -> URL {
        guard source.pathExtension.lowercased() != output.pathExtension.lowercased() else { return source }
        return source.deletingPathExtension().appendingPathExtension(output.pathExtension)
    }

    static let originalChanged = "The original changed during conversion"

    private static func keptBecause(_ reason: String) -> String {
        "The original was kept because \(reason)"
    }

    /// Throws `CancellationError` when the task was cancelled, after removing `output` (the runner's own file).
    private static func stopIfCancelled(removing output: URL) throws {
        guard Task.isCancelled else { return }
        try? FileManager.default.removeItem(at: output)
        throw CancellationError()
    }

    // MARK: - Encoding

    /// Names the output at write time, clears this job's stale partials, and encodes. A name taken between naming
    /// and commit moves on to the next name, up to `maxNamingAttempts`; nothing is overwritten.
    private func encode(
        source: URL, spec: DownscaleSpec, label: String, directory: URL, pathExtension: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        for _ in 0..<Self.maxNamingAttempts {
            let output = OutputNamer.url(for: source, label: label, in: directory, pathExtension: pathExtension)
            Self.removeStalePartials(of: output)
            do {
                try await VideoDownscaler().downscale(
                    source: source, output: output, spec: spec, progress: progress)
                return output
            } catch DownscaleError.outputExists {
                continue
            }
        }
        throw DownscaleRunnerError.nameTaken
    }

    /// "<N>p" for a real downscale; for keep-resolution, the preset's name, or "Compressed" for a custom spec.
    static func label(for spec: DownscaleSpec, settings: DownscaleJobSettings) -> String {
        if let target = spec.targetShortSide { return "\(target)p" }
        return settings.custom == nil ? settings.preset.displayName : "Compressed"
    }

    /// Verified: nothing lost beyond what was predicted, and no change beyond the expected ones.
    static func isVerified(_ report: MetadataReport, predicted: MetadataReport, spec: DownscaleSpec) -> Bool {
        warnings(report, predicted: predicted, spec: spec).isEmpty
    }

    /// One line per item lost beyond what was predicted, then one per unexpected change.
    static func warnings(_ report: MetadataReport, predicted: MetadataReport, spec: DownscaleSpec) -> [String] {
        let predictedLost = Set(predicted.lost.map(\.key))
        let lost = report.lost.filter { !predictedLost.contains($0.key) }.map { "\($0.displayName) is lost" }
        let changed = ExpectedChanges.unexpected(in: report, spec: spec).map {
            "\($0.displayName) changed from \($0.from) to \($0.to)"
        }
        return lost + changed
    }

    /// Deletes `.<final name>.partial-<UUID>` files beside `output`: leftovers of an interrupted run of this very
    /// output (or of a backup copy of it). Only names this app makes match: the suffix must parse as a UUID, and a
    /// directory is never removed, so a user's own hidden file or folder with a similar name is left alone.
    static func removeStalePartials(of output: URL) {
        let directory = output.deletingLastPathComponent()
        let prefix = "." + output.lastPathComponent + ".partial-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            let url = directory.appending(path: name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Files

    /// The bookmark's file if it still resolves (a moved file), else the recorded path. Must exist and not be in a
    /// Trash.
    static func resolveSource(_ job: Job) throws -> URL {
        var candidate = job.source
        if !job.sourceBookmark.isEmpty {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: job.sourceBookmark, options: [.withoutMounting, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            {
                candidate = resolved
            }
        }
        guard FileManager.default.fileExists(atPath: candidate.path), !isInTrash(candidate) else {
            throw DownscaleRunnerError.sourceUnavailable
        }
        return candidate
    }

    static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let userTrash = URL(filePath: NSHomeDirectory()).appending(path: ".Trash").standardizedFileURL.path
        if path == userTrash || path.hasPrefix(userTrash + "/") { return true }
        return url.standardizedFileURL.pathComponents.contains(".Trashes")
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func outputFolder(for destination: SaveDestination, source: URL) throws
        -> (url: URL, stop: () -> Void)
    {
        guard case .folder(let bookmark) = destination else {
            return (source.deletingLastPathComponent(), {})
        }
        var stale = false
        let url =
            (try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutMounting, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutMounting, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &stale))
        guard let url else { throw DownscaleRunnerError.outputFolderUnavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw DownscaleRunnerError.outputFolderUnavailable
        }
        return (url, { if scoped { url.stopAccessingSecurityScopedResource() } })
    }
}
