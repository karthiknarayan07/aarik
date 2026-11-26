import AppCore
import Foundation
import MediaEngine

public enum ConvertRunnerError: Error, LocalizedError, Equatable, OutcomeCoded {
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

    public var outcomeCode: OutcomeCode {
        switch self {
        case .sourceUnavailable: .originalUnavailable
        case .outputFolderUnavailable: .outputFolderUnavailable
        case .nameTaken: .outputNameTaken
        }
    }
}

public struct ConvertRunner: JobRunner {
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
    /// The free-space rule, checked before anything is written (see `STABILITY.md`).
    let diskSpace: DiskSpaceCheck

    /// `originalsBackup` is asked at the moment of each Replace, so a setting changed while the queue runs applies
    /// to the next Replace without rebuilding the runner or the queue.
    public init(originalsBackup: @escaping BackupProvider = { nil }) {
        self.init(trash: Self.trashItem, originalsBackup: originalsBackup)
    }

    /// Seams for tests: `trash` reports the Trash location of the fixture a test created, `inspect` reads the
    /// output's metadata (a test can make the output look unfaithful), `sizeOf` measures the output and the backup
    /// copy, `diskSpace` answers how much room each volume has.
    init(
        trash: @escaping Trasher,
        inspect: @escaping Inspector = { try await MediaInspector().inventory(of: $0) },
        sizeOf: @escaping Sizer = { try ConvertRunner.fileSize($0) },
        originalsBackup: @escaping BackupProvider = { nil },
        diskSpace: DiskSpaceCheck = DiskSpaceCheck()
    ) {
        self.diskSpace = diskSpace
        self.sizeOf = sizeOf
        self.trash = trash
        self.inspect = inspect
        self.originalsBackup = originalsBackup
    }

    static func trashItem(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    public func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        let settings = try JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
        defer { diskSpace.release(owner: job.id) }
        let source = try Self.resolveSource(job)
        // What the original is now; a Replace goes ahead only if it is still the same file at the end.
        let identity = try FileIdentity(of: source)
        let byteSize = identity.size
        let inventory = try await MediaInspector().inventory(of: source)

        let result = try await convert(
            source: source, byteSize: byteSize, inventory: inventory, settings: settings, reservingFor: job.id,
            outputFolder: { try Self.outputFolder(for: settings.saveTo, source: source) }, progress: progress)
        let converted: Conversion
        switch result {
        case .keptAsIs(let reason, let code): return .keptAsIs(reason: reason, code: code)
        case .converted(let value): converted = value
        }
        let output = converted.output
        var warnings = converted.warnings
        var notes = converted.notes

        var finalURL = output
        var replaced = false
        if settings.saveTo == .replace {
            // Only a verified output replaces the original, only once its backup (when that is on) is written and
            // checked, and only once the original is safely in the Trash. Otherwise nothing moves and the job
            // still completes with the output beside the original.
            if !warnings.isEmpty {
                warnings.append(Self.keptBecauseLine(Self.unverifiedCopyReason, .originalKeptNotVerified))
            } else {
                let result = replace(source, identity: identity, with: output)
                finalURL = result.url
                replaced = result.warning == nil
                if let warning = result.warning { warnings.append(warning) }
                if let note = result.note { notes.append(note) }
            }
        }
        return .completed(
            JobOutcome(
                output: finalURL, bytesBefore: byteSize, bytesAfter: converted.outputSize,
                report: converted.report, replacedOriginal: replaced, warnings: warnings.map(\.text),
                warningCodes: warnings.map(\.code), notes: notes.map(\.text), noteCodes: notes.map(\.code),
                source: source))
    }

    // MARK: - Planning, encoding and checking

    /// A converted output that passed the size check and the metadata comparison; it is the caller's to keep or
    /// remove.
    struct Conversion {
        let output: URL
        let outputSize: Int64
        let outputInventory: MetadataInventory
        let report: MetadataReport
        /// What was lost beyond the prediction or changed unexpectedly; empty means verified.
        let warnings: [OutcomeLine]
        /// Sentences that explain the result and are not problems.
        let notes: [OutcomeLine]
    }

    enum ConversionResult {
        /// Nothing was written: the original stays as it is, for this reason.
        case keptAsIs(String, OutcomeCode)
        case converted(Conversion)
    }

    /// The part of a run that doesn't depend on where the video came from: plan, encode into the folder
    /// `outputFolder` gives, remove the output when it saves too little, and compare its metadata with the source's.
    /// Any way out that doesn't hand back the output has removed it. `source` is read in place, never changed.
    /// `nameAfter` is the file the output is named after, when that isn't `source` (a Photos video's own name).
    func convert(
        source: URL, byteSize: Int64, inventory: MetadataInventory, settings: ConvertJobSettings,
        nameAfter: URL? = nil, requireLossShown: Bool = false, reservingFor owner: UUID? = nil,
        outputFolder: () throws -> (url: URL, stop: () -> Void),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        // An MPEG-4 source whose tracks MPEG-4 can't all carry is written as QuickTime; the planner counts what
        // that loses, which was shown before the job was added. Found only now (the add-time probe failed, or the
        // job predates predictions), that loss was never shown: keep the original as is, without encoding. Never
        // a silent loss; the check after the run stays as the backstop. The planner speaks first, so a video kept
        // for another reason (already small, too little saved) says that reason.
        let container = try await OutputContainer.decide(for: source)

        // Presets and custom specs go through the same planner: spatial check, Already small, 10% rule. The
        // planner's spec is the one encoded and verified (a slo-mo clip's frame-rate cap is dropped there).
        let requested = settings.custom ?? settings.preset.spec(for: inventory, byteSize: byteSize)
        let spec: DownscaleSpec
        let predicted: MetadataReport
        let estimatedBytes: Int64
        let decision = ConvertPlanner.decide(
            inventory: inventory, byteSize: byteSize, spec: requested,
            fallsBackToQuickTime: container.fallsBackToQuickTime)
        switch decision {
        case .keptAsIs(let reason, let code): return .keptAsIs(reason, code)
        case .convert(let planned, let estimate, let report):
            (spec, predicted, estimatedBytes) = (planned, report, estimate)
        }
        if container.fallsBackToQuickTime,
            !Self.fallbackLossWasShown(
                inventory, predictedLost: settings.predictedLost, predictedLostKeys: settings.predictedLostKeys)
        {
            return .keptAsIs(Self.formatCantKeepDetails, .formatCannotKeepDetails)
        }

        // A video whose details couldn't be listed when it was added (a Photos video isn't read until it runs) may
        // only lose what the user was shown then.
        if requireLossShown, let unshown = Self.unshownLoss(predicted, inventory: inventory, settings: settings) {
            return .keptAsIs(Self.lossNotShownReason(unshown), .lossNotShownBeforeAdding)
        }

        let folder = try outputFolder()
        defer { folder.stop() }
        // Nothing has been written yet: a volume too full for the output fails the job here, and Retry works.
        // A Replace with an originals backup also copies the original to the backup volume: checked now, not after
        // the encode.
        var needs = [SpaceNeed(url: folder.url, bytes: estimatedBytes)]
        if settings.saveTo == .replace, let backup = originalsBackup() {
            needs.append(SpaceNeed(url: backup.folder, bytes: byteSize))
        }
        try diskSpace.verify(needs, reservingFor: owner)
        let label = Self.label(for: spec, settings: settings)

        let output: URL
        do {
            output = try await encode(
                source: source, nameAfter: nameAfter ?? source, spec: spec, label: label, directory: folder.url,
                pathExtension: container.pathExtension, progress: progress)
        } catch DownscaleError.sourceAlreadySmall {
            return .keptAsIs(ConvertPlanner.alreadySmallReason, .alreadySmall)
        }

        // From here the output exists and is ours: any way out that doesn't keep it removes it.
        let outputSize: Int64
        let outputInventory: MetadataInventory
        do {
            // Cancelled once the output exists: remove it and leave the original alone.
            try Self.stopIfCancelled(removing: output)
            // The estimate can overstate the saving (heavy audio counted as video). If the real output is not at
            // least 10% smaller, remove our own output and keep the original untouched.
            outputSize = try sizeOf(output)
            if outputSize >= byteSize * 9 / 10 {
                try? FileManager.default.removeItem(at: output)
                return .keptAsIs(ConvertPlanner.savesLittleReason, .savesLittle)
            }
            outputInventory = try await Signposts.interval(.verify) { try await inspect(output) }
            try Self.stopIfCancelled(removing: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        let report = Signposts.interval(.verify) { MetadataDiff.report(source: inventory, output: outputInventory) }

        // In another container, anything lost beyond the prediction is a loss nobody was told about: never keep
        // such a copy, wherever it was to be saved.
        if Self.changesContainer(source: source, output: output),
            !Self.unpredictedLosses(report, predicted: predicted).isEmpty
        {
            try? FileManager.default.removeItem(at: output)
            return .keptAsIs(Self.formatCantKeepDetails, .formatCannotKeepDetails)
        }
        var notes: [OutcomeLine] = []
        if container.fallsBackToQuickTime {
            notes.append(
                OutcomeLine(
                    Self.containerNote(source: source, pathExtension: container.pathExtension), .containerChanged))
        }
        return .converted(
            Conversion(
                output: output, outputSize: outputSize, outputInventory: outputInventory, report: report,
                warnings: Self.warningLines(report, predicted: predicted, spec: spec), notes: notes))
    }

    /// Whether what leaving MPEG-4 for QuickTime loses was shown before the job was added: every lost item's key
    /// is in `predictedLostKeys`, or, for a job saved before keys were recorded, every item is named in
    /// `predictedLost` (by its plain name, or by the four-character code older sheets showed for ISO user data).
    /// A job without a prediction showed nothing.
    static func fallbackLossWasShown(
        _ inventory: MetadataInventory, predictedLost: [String]?, predictedLostKeys: [String]?
    ) -> Bool {
        let lost = OutputContainer.lostInQuickTimeFallback(inventory)
        if lost.isEmpty { return true }
        if let predictedLostKeys { return Set(lost.map(\.key)).isSubset(of: predictedLostKeys) }
        guard let predictedLost else { return false }
        let shown = Set(predictedLost)
        return lost.allSatisfy { item in
            shown.contains(MetadataNames.plainName(of: item))
                || MetadataNames.isoUserDataCode(forKey: item.key).map(shown.contains) == true
        }
    }

    /// The predicted losses that were not among the names shown when the job was added, as a sentence part, or
    /// nil when all were shown. HDR items count as shown when "HDR details" was.
    static func unshownLoss(
        _ predicted: MetadataReport, inventory: MetadataInventory, settings: ConvertJobSettings
    ) -> String? {
        let shown = Set(settings.predictedLost ?? [])
        let auxiliary = MetadataNames.auxiliaryTracks(in: inventory.items)
        let unshown = predicted.lost.filter { item in
            if item.category == .hdr, shown.contains(PhotosLossCheck.hdrDetails) { return false }
            return !shown.contains(MetadataNames.plainName(of: item, auxiliaryTracks: auxiliary))
        }
        guard !unshown.isEmpty else { return nil }
        return MetadataNames.plainNames(of: unshown, context: inventory.items).map { $0.lowercased() }
            .joined(separator: ", ")
    }

    static let formatCantKeepDetails = "Its file format can't keep all of its details"

    /// The output has another extension than the source, so another container.
    static func changesContainer(source: URL, output: URL) -> Bool {
        source.pathExtension.lowercased() != output.pathExtension.lowercased()
    }

    // MARK: - Replace

    /// Backs the original up when asked to, trashes it, and gives the output the original's name (with the
    /// output's extension, when the container changed) if that is still free. The original must still be the
    /// file the conversion read. Returns where the output ends up, the warning saying why the original was kept
    /// when it was, and a note when the output couldn't take the original's name.
    private func replace(_ source: URL, identity: FileIdentity, with output: URL)
        -> (url: URL, warning: OutcomeLine?, note: OutcomeLine?)
    {
        let changed = OutcomeLine(Self.originalChanged, .originalChangedDuringConversion)
        guard identity.matches(source) else { return (output, changed, nil) }
        if let backup = originalsBackup() {
            do {
                _ = try backUp(source, byteSize: identity.size, into: backup.folder)
            } catch {
                return (output, Self.keptBecauseLine(error.keptBecause, .originalKeptBackupFailed), nil)
            }
        }
        guard identity.matches(source) else { return (output, changed, nil) }
        guard (try? trash(source)) != nil else {
            return (output, Self.keptBecauseLine(Self.trashFailedReason, .originalKeptCouldNotTrash), nil)
        }
        // Take the original's name if it is still free, else keep the output's own name and say why.
        let target = Self.replacementURL(for: source, output: output)
        if (try? AtomicOutput.moveWithoutReplacing(output, to: target)) != nil { return (target, nil, nil) }
        let why = FileManager.default.fileExists(atPath: target.path) ? "already exists" : "couldn't be used"
        let note = Self.renamedNote(output: output, target: target, why: why)
        return (output, nil, OutcomeLine(note, .nameChanged))
    }

    static func lossNotShownReason(_ unshown: String) -> String {
        "Converting would lose \(unshown), which wasn't known when it was added"
    }

    static func containerNote(source: URL, pathExtension: String) -> String {
        "Saved as a .\(pathExtension) file because \(source.pathExtension.uppercased()) can't hold "
            + "all of its tracks"
    }

    static func renamedNote(output: URL, target: URL, why: String) -> String {
        "Saved as “\(output.lastPathComponent)” because “\(target.lastPathComponent)” \(why)"
    }

    /// The original's path, with the output's extension when the output is in another container
    /// (`IMG_1.mp4` replaced by a QuickTime file becomes `IMG_1.mov`).
    static func replacementURL(for source: URL, output: URL) -> URL {
        guard source.pathExtension.lowercased() != output.pathExtension.lowercased() else { return source }
        return source.deletingPathExtension().appendingPathExtension(output.pathExtension)
    }

    static let originalChanged = "The original changed during conversion"

    static let unverifiedCopyReason = "the copy couldn't be verified"
    static let trashFailedReason = "it couldn't be moved to the Trash"

    static func keptBecause(_ reason: String) -> String {
        "The original was kept because \(reason)"
    }

    static func keptBecauseLine(_ reason: String, _ code: OutcomeCode) -> OutcomeLine {
        OutcomeLine(keptBecause(reason), code)
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
        source: URL, nameAfter: URL, spec: DownscaleSpec, label: String, directory: URL, pathExtension: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        for _ in 0..<Self.maxNamingAttempts {
            let output = OutputNamer.url(for: nameAfter, label: label, in: directory, pathExtension: pathExtension)
            Self.removeStalePartials(of: output)
            do {
                try await VideoDownscaler().downscale(
                    source: source, output: output, spec: spec, progress: progress)
                return output
            } catch DownscaleError.outputExists {
                continue
            }
        }
        throw ConvertRunnerError.nameTaken
    }

    /// "<N>p" for a real downscale; for keep-resolution, the preset's name, or "Compressed" for a custom spec.
    static func label(for spec: DownscaleSpec, settings: ConvertJobSettings) -> String {
        if let target = spec.targetShortSide { return "\(target)p" }
        return settings.custom == nil ? settings.preset.displayName : "Compressed"
    }

    /// Verified: nothing lost beyond what was predicted, and no change beyond the expected ones.
    static func isVerified(_ report: MetadataReport, predicted: MetadataReport, spec: DownscaleSpec) -> Bool {
        warnings(report, predicted: predicted, spec: spec).isEmpty
    }

    /// What the output lost that the prediction didn't name.
    static func unpredictedLosses(_ report: MetadataReport, predicted: MetadataReport) -> [MetadataItem] {
        let predictedLost = Set(predicted.lost.map(\.key))
        return report.lost.filter { !predictedLost.contains($0.key) }
    }

    /// One line per thing lost beyond what was predicted (plain names, each once: a Cinematic track and its
    /// metadata are one line), then one per unexpected change.
    static func warnings(_ report: MetadataReport, predicted: MetadataReport, spec: DownscaleSpec) -> [String] {
        warningLines(report, predicted: predicted, spec: spec).map(\.text)
    }

    /// The same warnings with their codes.
    static func warningLines(_ report: MetadataReport, predicted: MetadataReport, spec: DownscaleSpec)
        -> [OutcomeLine]
    {
        let context = report.kept + report.lost
        let lost = MetadataNames.plainNames(of: unpredictedLosses(report, predicted: predicted), context: context)
            .map { OutcomeLine("\($0) is lost", .unexpectedLoss) }
        let auxiliary = MetadataNames.auxiliaryTracks(in: context)
        let changed = ExpectedChanges.unexpected(in: report, spec: spec).map {
            OutcomeLine(MetadataNames.changeSentence($0, auxiliaryTracks: auxiliary), .unexpectedChange)
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
            throw ConvertRunnerError.sourceUnavailable
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

    static func outputFolder(for destination: SaveDestination, source: URL) throws
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
        guard let url else { throw ConvertRunnerError.outputFolderUnavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw ConvertRunnerError.outputFolderUnavailable
        }
        return (url, { if scoped { url.stopAccessingSecurityScopedResource() } })
    }
}
