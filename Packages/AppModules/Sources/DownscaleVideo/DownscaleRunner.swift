import AppCore
import Darwin
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

    private static let maxNamingAttempts = 3
    private let trash: Trasher

    public init() {
        self.init(trash: Self.trashItem)
    }

    /// `trash` is a seam for tests, which need the Trash location of the fixture they created.
    init(trash: @escaping Trasher) {
        self.trash = trash
    }

    private static func trashItem(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    public func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        let settings = try JSONDecoder().decode(DownscaleJobSettings.self, from: job.settings)
        let source = try Self.resolveSource(job)
        let byteSize = try Self.fileSize(source)
        let inventory = try await MediaInspector().inventory(of: source)

        let spec: DownscaleSpec
        let predicted: MetadataReport
        if let custom = settings.custom {
            // A custom spec is the user's explicit choice: no savings check, only what the downscaler refuses.
            if inventory["hdr.stereo"] != nil { return .keptAsIs(reason: DownscalePlanner.spatialReason) }
            spec = custom
            predicted = DownscalePlanner.predicted(inventory: inventory, spec: custom)
        } else {
            let decision = DownscalePlanner.decide(
                source: source, inventory: inventory, byteSize: byteSize, preset: settings.preset)
            switch decision {
            case .keptAsIs(let reason): return .keptAsIs(reason: reason)
            case .convert(let planned, _, let report): (spec, predicted) = (planned, report)
            }
        }

        let folder = try Self.outputFolder(for: settings.saveTo, source: source)
        defer { folder.stop() }
        let label = Self.label(for: spec)

        let output: URL
        do {
            output = try await encode(
                source: source, spec: spec, label: label, directory: folder.url, progress: progress)
        } catch DownscaleError.sourceAlreadySmall {
            return .keptAsIs(reason: "Already small")
        }

        let outputInventory = try await MediaInspector().inventory(of: output)
        let report = MetadataDiff.report(source: inventory, output: outputInventory)
        let predictedLost = Set(predicted.lost.map(\.key))
        let verified = report.lost.allSatisfy { predictedLost.contains($0.key) }

        var finalURL = output
        var replaced = false
        if settings.saveTo == .replace, verified, (try? trash(source)) != nil {
            replaced = true
            // The original is in the Trash; take its name if it is still free, else keep the output's own name.
            if Self.renameExclusively(output, to: source) { finalURL = source }
        }
        return .completed(
            JobOutcome(
                output: finalURL, bytesBefore: byteSize, bytesAfter: try Self.fileSize(finalURL),
                report: report, replacedOriginal: replaced))
    }

    // MARK: - Encoding

    /// Names the output at write time, clears this job's stale partials, and encodes. A name taken between naming
    /// and commit moves on to the next name, up to `maxNamingAttempts`; nothing is overwritten.
    private func encode(
        source: URL, spec: DownscaleSpec, label: String, directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        for _ in 0..<Self.maxNamingAttempts {
            let output = OutputNamer.url(for: source, label: label, in: directory)
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

    static func label(for spec: DownscaleSpec) -> String {
        spec.targetShortSide.map { "\($0)p" } ?? "High"
    }

    /// Deletes `.<final name>.partial-*` beside `output`: leftovers of an interrupted run of this very output.
    private static func removeStalePartials(of output: URL) {
        let directory = output.deletingLastPathComponent()
        let prefix = "." + output.lastPathComponent + ".partial-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
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
                resolvingBookmarkData: job.sourceBookmark, options: [], relativeTo: nil,
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

    private static func fileSize(_ url: URL) throws -> Int64 {
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
                resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &stale))
            ?? (try? URL(
                resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
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

    /// Renames `from` to `to` only if nothing exists at `to`. Returns whether it did.
    private static func renameExclusively(_ from: URL, to destination: URL) -> Bool {
        renamex_np(from.path, destination.path, UInt32(RENAME_EXCL)) == 0
    }
}
