import AppCore
import Foundation
import MediaEngine

/// Runs local file image conversion jobs safely using atomic output, metadata diff verification, and Trash-only Replace.
public struct ImageConvertRunner: JobRunner {
    private let core: ConvertRunner

    public init(originalsBackup: @escaping ConvertRunner.BackupProvider = { nil }) {
        self.core = ConvertRunner(originalsBackup: originalsBackup)
    }

    init(core: ConvertRunner) {
        self.core = core
    }

    public func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        let settings = try JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
        defer { core.diskSpace.release(owner: job.id) }
        let resolved = try ConvertRunner.resolveSource(job)
        defer { resolved.stop() }
        let source = resolved.url

        let identity = try FileIdentity(of: source)
        let byteSize = identity.size
        let inspector = ImageInspector()
        let inspection = try inspector.inspect(url: source)
        let inventory = try inspector.inventory(of: source)
        let spec = settings.imageSpec ?? ImageSpec()

        let result = try await convert(
            source: source,
            byteSize: byteSize,
            inspection: inspection,
            inventory: inventory,
            settings: settings,
            spec: spec,
            reservingFor: job.id,
            outputFolder: {
                try ConvertRunner.outputFolder(
                    for: settings.saveTo, source: source, documentsDirectory: core.documentsDirectory)
            },
            progress: progress
        )

        let converted: ConvertRunner.Conversion
        switch result {
        case .keptAsIs(let reason, let code):
            return .keptAsIs(reason: reason, code: code)
        case .converted(let value):
            converted = value
        }

        let output = converted.output
        var warnings = converted.warnings
        var notes = converted.notes
        var finalURL = output
        var replaced = false

        if settings.saveTo == .replace {
            if !warnings.isEmpty {
                warnings.append(
                    ConvertRunner.keptBecauseLine(ConvertRunner.unverifiedCopyReason, .originalKeptNotVerified))
            } else {
                let replaceResult = core.replace(source, identity: identity, with: output)
                finalURL = replaceResult.url
                replaced = replaceResult.warning == nil
                if let warning = replaceResult.warning { warnings.append(warning) }
                if let note = replaceResult.note { notes.append(note) }
            }
        }

        return .completed(
            JobOutcome(
                output: finalURL, bytesBefore: byteSize, bytesAfter: converted.outputSize,
                report: converted.report, replacedOriginal: replaced,
                warnings: warnings.map(\.text), warningCodes: warnings.map(\.code),
                notes: notes.map(\.text), noteCodes: notes.map(\.code),
                source: source))
    }

    /// Core reusable image conversion pipeline shared between Local Files and Photos image runs.
    func convert(
        source: URL,
        byteSize: Int64,
        inspection: ImageInspection,
        inventory: MetadataInventory,
        settings: ConvertJobSettings,
        spec: ImageSpec,
        nameAfter: URL? = nil,
        requireLossShown: Bool = false,
        reservingFor owner: UUID? = nil,
        outputFolder: () throws -> (url: URL, stop: () -> Void),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConvertRunner.ConversionResult {
        let decision = ImagePlanner.decide(
            byteSize: byteSize,
            pixelSize: inspection.pixelSize,
            sourceUTI: inspection.sourceUTI,
            inventory: inventory,
            spec: spec
        )

        let resolvedSpec: ImageSpec
        let outputFormat: ImageOutputFormat
        let predicted: MetadataReport
        let estimatedBytes: Int64
        switch decision {
        case .keptAsIs(let reason, let code):
            return .keptAsIs(reason, code)
        case .convert(let planned, let format, _, let estimate, let report):
            (resolvedSpec, outputFormat, predicted, estimatedBytes) = (planned, format, report, estimate)
        }

        if requireLossShown, let unshown = Self.unshownLoss(predicted, inventory: inventory, settings: settings) {
            return .keptAsIs(ConvertRunner.lossNotShownReason(unshown), .lossNotShownBeforeAdding)
        }

        let folder = try outputFolder()
        defer { folder.stop() }
        var needs = [SpaceNeed(url: folder.url, bytes: estimatedBytes)]
        if settings.saveTo == .replace, let backup = core.originalsBackup() {
            needs.append(SpaceNeed(url: backup.folder, bytes: byteSize))
        }
        try core.diskSpace.verify(needs, reservingFor: owner)

        let label = ImageAdvancedOptions.label(for: resolvedSpec)
        let targetExt = outputFormat.fileExtension ?? source.pathExtension
        let output: URL
        do {
            output = try await encode(
                source: source, nameAfter: nameAfter ?? source, spec: resolvedSpec, label: label,
                directory: folder.url, pathExtension: targetExt, progress: progress)
        } catch ImageConversionError.sourceAlreadySmall {
            return .keptAsIs(ImagePlanner.alreadySmallReason, .alreadySmall)
        }

        let outputSize: Int64
        let outputInventory: MetadataInventory
        do {
            try ConvertRunner.stopIfCancelled(removing: output)
            outputSize = try core.sizeOf(output)
            let sourceFormat = ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: inspection.sourceUTI)
            let sameFormat =
                outputFormat == sourceFormat && !inspection.isRAW
                && !ImagePlanner.isWebPOrReadOnly(inspection.sourceUTI)
            if sameFormat, resolvedSpec.targetByteSize == nil, !resolvedSpec.isLossless,
                outputSize >= byteSize * 9 / 10
            {
                try? FileManager.default.removeItem(at: output)
                return .keptAsIs(ImagePlanner.savesLittleReason, .savesLittle)
            }
            outputInventory = try Signposts.interval(.verify) { try ImageInspector().inventory(of: output) }
            try ConvertRunner.stopIfCancelled(removing: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }

        let report = Signposts.interval(.verify) { MetadataDiff.report(source: inventory, output: outputInventory) }
        var notes: [OutcomeLine] = []
        if ConvertRunner.changesContainer(source: nameAfter ?? source, output: output) {
            notes.append(OutcomeLine("Saved as \(outputFormat.title)", .containerChanged))
        }
        return .converted(
            ConvertRunner.Conversion(
                output: output, outputSize: outputSize, outputInventory: outputInventory, report: report,
                warnings: Self.warningLines(report, predicted: predicted, spec: resolvedSpec), notes: notes))
    }

    private func encode(
        source: URL, nameAfter: URL, spec: ImageSpec, label: String, directory: URL,
        pathExtension: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        for _ in 0..<ConvertRunner.maxNamingAttempts {
            let output = OutputNamer.url(for: nameAfter, label: label, in: directory, pathExtension: pathExtension)
            ConvertRunner.removeStalePartials(of: output)
            do {
                _ = try await ImageConverter().convert(
                    source: source, to: output, spec: spec, progress: progress)
                return output
            } catch ImageConversionError.outputExists {
                continue
            }
        }
        throw ConvertRunnerError.nameTaken
    }

    static func warningLines(_ report: MetadataReport, predicted: MetadataReport, spec: ImageSpec) -> [OutcomeLine] {
        let context = report.kept + report.lost
        let lost = MetadataNames.plainNames(
            of: ConvertRunner.unpredictedLosses(report, predicted: predicted), context: context
        )
        .map { OutcomeLine("\($0) is lost", .unexpectedLoss) }
        let changed = ExpectedChanges.unexpected(in: report, spec: spec).map {
            OutcomeLine(MetadataNames.changeSentence($0), .unexpectedChange)
        }
        return lost + changed
    }

    static func unshownLoss(
        _ predicted: MetadataReport, inventory: MetadataInventory, settings: ConvertJobSettings
    ) -> String? {
        let shown = Set(settings.predictedLost ?? [])
        let unshown = predicted.lost.filter { item in
            if let keys = settings.predictedLostKeys {
                return !keys.contains(item.key)
            }
            return !shown.contains(MetadataNames.plainName(of: item))
        }
        guard !unshown.isEmpty else { return nil }
        return MetadataNames.plainNames(of: unshown, context: inventory.items).map { $0.lowercased() }
            .joined(separator: ", ")
    }
}
