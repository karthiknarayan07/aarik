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
/// The prompt holds metadata names and sizes only: never a file name or path, and never a metadata value such as
/// a location. Without an answer (error, refusal, timeout) the result's existing text is shown instead.
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

    static func prompt(job: Job, outcome: JobOutcome?, report: MetadataReport?) -> String {
        let report = report ?? outcome?.report
        let redact = Redactor(job: job, outcome: outcome)
        var lines: [String] = []
        switch job.state {
        case .completed(let done):
            lines.append("Result: \(done.isVerified ? "completed" : "completed with warnings")")
        case .keptAsIs(let reason):
            lines.append("Result: kept as is, no new file was made")
            lines.append("Reason: \(redact(reason))")
        case .failed(let reason):
            lines.append("Result: failed")
            lines.append("Reason: \(redact(reason))")
        case .queued, .running:
            lines.append("Result: not finished")
        }
        if let settings = settings(of: job) {
            lines.append("Preset: \(settings.custom == nil ? settings.preset.displayName : "Custom settings")")
            if let predicted = settings.predictedLost {
                lines.append("Predicted losses: \(predicted.isEmpty ? "none" : predicted.joined(separator: ", "))")
            }
        }
        if let outcome {
            lines.append("Size before: \(ByteFormat.string(outcome.bytesBefore))")
            lines.append("Size after: \(ByteFormat.string(outcome.bytesAfter))")
            lines.append("Original replaced: \(outcome.replacedOriginal ? "yes" : "no")")
        }
        if let report {
            lines.append("Actual losses: \(names(report.lost.map(\.displayName)))")
            lines.append("Changed: \(names(report.changed.map(\.displayName)))")
            lines.append("Kept: \(report.kept.count) items")
        }
        if let outcome {
            for warning in outcome.warnings { lines.append("Warning: \(redact(warning))") }
            for note in outcome.notes { lines.append("Note: \(redact(note))") }
        }
        return lines.joined(separator: "\n")
    }

    private static func names(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private static func settings(of job: Job) -> DownscaleJobSettings? {
        guard job.toolID == DownscaleTool.toolID else { return nil }
        return try? JSONDecoder().decode(DownscaleJobSettings.self, from: job.settings)
    }

    /// Takes file names and paths out of text that is about to be sent. Whole names and paths go first; then
    /// names without their extension, only as whole words of four or more letters (so "video" in "Video track
    /// was kept" stays unless the file is called exactly that); then anything that looks like a path or a movie
    /// file name. Text such as "H.264/AAC" is left alone.
    private struct Redactor {
        let literals: [String]
        let stems: [NSRegularExpression]

        static let pathPattern = try? NSRegularExpression(
            pattern: #"(?<![\w.])/(?:[^\s/]+/)*[^\s/]*"#)
        static let moviePattern = try? NSRegularExpression(
            pattern: #"\S+\.(?:mov|mp4|m4v|hevc|mkv|avi)\b"#, options: .caseInsensitive)

        init(job: Job, outcome: JobOutcome?) {
            var urls = [job.source, job.sourceUsed]
            if let outcome {
                urls.append(outcome.output)
                if let source = outcome.source { urls.append(source) }
            }
            var literals: [String] = []
            for url in urls {
                literals.append(url.path)
                literals.append(url.deletingLastPathComponent().path)
                literals.append(url.lastPathComponent)
            }
            self.literals = Array(Set(literals.filter { $0.count > 1 })).sorted { $0.count > $1.count }
            let stems = Set(urls.map { $0.deletingPathExtension().lastPathComponent }.filter { $0.count >= 4 })
            self.stems = stems.sorted { $0.count > $1.count }.compactMap {
                try? NSRegularExpression(
                    pattern: #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: $0) + #"(?!\w)"#,
                    options: .caseInsensitive)
            }
        }

        func callAsFunction(_ text: String) -> String {
            var result = text
            for literal in literals { result = result.replacingOccurrences(of: literal, with: "the file") }
            for expression in stems + [Self.moviePattern, Self.pathPattern].compactMap({ $0 }) {
                result = expression.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "the file")
            }
            // Free text is capped, so a long error message can't carry much.
            return String(result.prefix(300))
        }
    }

    // MARK: Fallback

    /// The result's existing text: its reason, or its warnings and notes.
    static func fallback(job: Job, outcome: JobOutcome?) -> String {
        switch job.state {
        case .keptAsIs(let reason), .failed(let reason): return reason
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
