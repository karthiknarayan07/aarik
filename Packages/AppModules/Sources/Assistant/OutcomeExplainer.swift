import AppCore
import AppUI
import DownscaleVideo
import Foundation
import Observation

/// A plain-language explanation of one result, and whether the model wrote it.
public struct OutcomeExplanation: Sendable, Equatable {
    public let text: String
    /// False when the model gave no answer and `text` is the result's own reason text.
    public let isGenerated: Bool
}

/// Explains a result in two to four plain sentences, from the job's own report: reason, notes and warnings,
/// predicted versus actual losses, sizes and preset.
///
/// The prompt is built from structured fields only (see `prompt`): the result's reason codes, never a file name or
/// path, never a metadata value such as a location, and never the result's free-text reasons. Without an answer (error, refusal,
/// timeout) the result's existing text is shown instead.
public struct OutcomeExplainer: Sendable {
    let client: any LanguageModelClient
    let timeout: Duration

    public init(client: any LanguageModelClient, timeout: Duration = .seconds(20)) {
        self.client = client
        self.timeout = timeout
    }

    static let instructions = """
        You explain the result of a video conversion to a person who is not technical. Write two to four short \
        plain sentences. Use only the facts you are given; never guess a cause that is not stated. Say what \
        happened, what was lost or changed and why when the facts say so, and what the person can do only if the \
        facts suggest it. Do not mention file names. Do not use lists or headings.
        """

    public func explain(job: Job, outcome: JobOutcome?, report: MetadataReport?) async -> String {
        await explanation(job: job, outcome: outcome, report: report).text
    }

    public func explanation(job: Job, outcome: JobOutcome?, report: MetadataReport?) async -> OutcomeExplanation {
        let fallback = OutcomeExplanation(text: Self.fallback(job: job, outcome: outcome), isGenerated: false)
        guard client.isAvailable else { return fallback }
        let prompt = Self.prompt(job: job, outcome: outcome, report: report)
        do {
            let client = self.client
            let answer = try await Deadline.run(timeout) {
                try await client.respond(to: prompt, instructions: Self.instructions)
            }
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : OutcomeExplanation(text: text, isGenerated: true)
        } catch {
            return fallback
        }
    }

    // MARK: Prompt

    /// The facts the model reads, built only from structured fields: the result's kind, reason codes (see
    /// `OutcomeCode`), plain metadata names from `MetadataNames`, sizes, the preset and the codec and
    /// resolution labels, and the names of predicted and actual losses. The result's own reason, warning and
    /// note texts are never included: they can hold a file name, a folder or a metadata value.
    static func prompt(job: Job, outcome: JobOutcome?, report: MetadataReport?) -> String {
        let report = report ?? outcome?.report
        var lines: [String] = []
        switch job.state {
        case .completed(let done):
            lines.append("Result: \(done.isVerified ? "completed" : "completed with warnings")")
        case .keptAsIs(_, let code):
            lines.append("Result: kept as is, no new file was made")
            lines.append("Reason: \(code.sentence)")
        case .failed(_, let code):
            lines.append("Result: failed")
            lines.append("Reason: \(code.sentence)")
        case .queued, .running:
            lines.append("Result: not finished")
        }
        if let settings = settings(of: job) {
            lines.append(contentsOf: settingsLines(settings))
            if let predicted = settings.predictedLost {
                let names = PromptMetadataNames.names(predicted: predicted, keys: settings.predictedLostKeys)
                lines.append("Predicted losses: \(list(names))")
            }
        }
        if let outcome {
            lines.append("Size before: \(ByteFormat.string(outcome.bytesBefore))")
            lines.append("Size after: \(ByteFormat.string(outcome.bytesAfter))")
            lines.append("Original replaced: \(outcome.replacedOriginal ? "yes" : "no")")
        }
        if let report {
            let context = report.kept + report.lost
            lines.append("Actual losses: \(list(PromptMetadataNames.names(of: report.lost, context: context)))")
            lines.append("Changed: \(list(PromptMetadataNames.names(of: report.changed, context: context)))")
            lines.append("Kept: \(report.kept.count) items")
        }
        if let outcome {
            for code in distinct(outcome.warningCodes) { lines.append("Warning: \(code.sentence)") }
            for code in distinct(outcome.noteCodes) { lines.append("Note: \(code.sentence)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Each code once, in order.
    private static func distinct(_ codes: [OutcomeCode]) -> [OutcomeCode] {
        var seen = Set<OutcomeCode>()
        return codes.filter { seen.insert($0).inserted }
    }

    private static func list(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private static func settingsLines(_ settings: DownscaleJobSettings) -> [String] {
        guard let custom = settings.custom else { return ["Preset: \(settings.preset.displayName)"] }
        var lines = ["Preset: Custom settings"]
        lines.append(
            "Resolution: \(custom.targetShortSide.map { "\($0)p short side" } ?? "kept as in the original")")
        lines.append("Codec: \(custom.codec == .h264Compatible ? "H.264 (SDR)" : "HEVC (keeps HDR)")")
        if let rate = custom.maxFrameRate { lines.append("Frame rate: capped at \(Int(rate)) fps") }
        return lines
    }

    private static func settings(of job: Job) -> DownscaleJobSettings? {
        guard job.toolID == DownscaleTool.toolID || job.toolID == DownscaleTool.photosToolID else { return nil }
        return try? JSONDecoder().decode(DownscaleJobSettings.self, from: job.settings)
    }

    // MARK: Fallback

    /// The result's existing text: its reason, or its warnings and notes.
    static func fallback(job: Job, outcome: JobOutcome?) -> String {
        switch job.state {
        case .keptAsIs(let reason, _), .failed(let reason, _): return reason
        case .completed(let done):
            let text = (done.warnings + done.notes).joined(separator: " ")
            return text.isEmpty ? "Nothing unexpected was lost or changed." : text
        case .queued, .running: return ""
        }
    }
}

/// Explanations kept per job, so asking again doesn't ask the model again. Only answers the model wrote are
/// kept; a fallback is shown but not remembered, so a later try can succeed. An explanation is written again
/// when the job's result changed (a retry).
@MainActor
@Observable
public final class OutcomeExplanations {
    private struct Entry {
        let prompt: String
        let text: String
    }

    private struct Running {
        let prompt: String
        let task: Task<String, Never>
    }

    private let explainer: OutcomeExplainer
    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var running: [UUID: Running] = [:]

    public init(explainer: OutcomeExplainer) {
        self.explainer = explainer
    }

    /// The remembered explanation for a job, if any.
    public func cached(for id: UUID) -> String? { entries[id]?.text }

    /// Two asks for the same job at once (the row's popover and the report's) share one model call.
    public func explain(job: Job, outcome: JobOutcome?) async -> String {
        let prompt = OutcomeExplainer.prompt(job: job, outcome: outcome, report: outcome?.report)
        if let entry = entries[job.id], entry.prompt == prompt { return entry.text }
        if let current = running[job.id], current.prompt == prompt { return await current.task.value }
        let explainer = self.explainer
        let id = job.id
        let task = Task { [weak self] () -> String in
            let explanation = await explainer.explanation(job: job, outcome: outcome, report: outcome?.report)
            if let self {
                if explanation.isGenerated { entries[id] = Entry(prompt: prompt, text: explanation.text) }
                running[id] = nil
            }
            return explanation.text
        }
        running[id] = Running(prompt: prompt, task: task)
        return await task.value
    }
}
