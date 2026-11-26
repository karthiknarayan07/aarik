import Foundation

/// What a finished conversion produced.
public struct JobOutcome: Codable, Sendable, Equatable {
    public var output: URL
    public var bytesBefore: Int64
    public var bytesAfter: Int64
    public var report: MetadataReport
    public var replacedOriginal: Bool
    /// What the runner found wrong, decided once when the job finished: metadata lost or changed beyond what the
    /// conversion is expected to do, or a requested Replace that didn't happen. Empty means verified.
    public private(set) var warnings: [String]
    /// The code of each warning, in the same order and always as many as `warnings`.
    public private(set) var warningCodes: [OutcomeCode]
    /// Sentences explaining the result that are not problems, such as why the file got another name or format.
    public private(set) var notes: [String]
    /// The code of each note, in the same order and always as many as `notes`.
    public private(set) var noteCodes: [OutcomeCode]
    /// The file the run read: the job's path, or where its bookmark found the file after it moved. Nil for
    /// outcomes saved before this was recorded.
    public var source: URL?

    /// `warningCodes` and `noteCodes` pair with the texts by position; a missing code is `.other`, an extra one is
    /// dropped.
    public init(
        output: URL,
        bytesBefore: Int64,
        bytesAfter: Int64,
        report: MetadataReport,
        replacedOriginal: Bool,
        warnings: [String] = [],
        warningCodes: [OutcomeCode] = [],
        notes: [String] = [],
        noteCodes: [OutcomeCode] = [],
        source: URL? = nil
    ) {
        self.output = output
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.report = report
        self.replacedOriginal = replacedOriginal
        self.warnings = warnings
        self.warningCodes = Self.paired(warningCodes, with: warnings)
        self.notes = notes
        self.noteCodes = Self.paired(noteCodes, with: notes)
        self.source = source
    }

    /// Reads outcomes saved before `warnings`, `notes`, their codes or `source` existed as having none; a text
    /// without a code reads as `.other`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try container.decode(URL.self, forKey: .output)
        bytesBefore = try container.decode(Int64.self, forKey: .bytesBefore)
        bytesAfter = try container.decode(Int64.self, forKey: .bytesAfter)
        report = try container.decode(MetadataReport.self, forKey: .report)
        replacedOriginal = try container.decode(Bool.self, forKey: .replacedOriginal)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        warningCodes = Self.paired(
            try container.decodeIfPresent([OutcomeCode].self, forKey: .warningCodes) ?? [], with: warnings)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        noteCodes = Self.paired(
            try container.decodeIfPresent([OutcomeCode].self, forKey: .noteCodes) ?? [], with: notes)
        source = try container.decodeIfPresent(URL.self, forKey: .source)
    }

    private static func paired(_ codes: [OutcomeCode], with texts: [String]) -> [OutcomeCode] {
        Array((codes + Array(repeating: .other, count: max(0, texts.count - codes.count))).prefix(texts.count))
    }

    /// Adds a warning unless the same text is already there.
    public mutating func addWarning(_ text: String, code: OutcomeCode) {
        guard !warnings.contains(text) else { return }
        warnings.append(text)
        warningCodes.append(code)
    }

    /// Adds a note unless the same text is already there.
    public mutating func addNote(_ text: String, code: OutcomeCode) {
        guard !notes.contains(text) else { return }
        notes.append(text)
        noteCodes.append(code)
    }

    /// Removes every warning that satisfies `shouldRemove`, which is given the text and the code.
    public mutating func removeWarnings(where shouldRemove: (String, OutcomeCode) -> Bool) {
        let kept = zip(warnings, warningCodes).filter { !shouldRemove($0, $1) }
        warnings = kept.map(\.0)
        warningCodes = kept.map(\.1)
    }

    /// Removes every note that satisfies `shouldRemove`, which is given the text and the code.
    public mutating func removeNotes(where shouldRemove: (String, OutcomeCode) -> Bool) {
        let kept = zip(notes, noteCodes).filter { !shouldRemove($0, $1) }
        notes = kept.map(\.0)
        noteCodes = kept.map(\.1)
    }

    /// Nothing unexpected was lost or changed, and a requested Replace happened.
    public var isVerified: Bool { warnings.isEmpty }

    /// Bytes freed; never negative.
    public var savedBytes: Int64 { max(0, bytesBefore - bytesAfter) }
}

public enum JobState: Sendable, Equatable {
    case queued
    case running(progress: Double)
    case completed(JobOutcome)
    /// No new file was made; `reason` is the sentence for the person, `code` the same reason for the app.
    case keptAsIs(reason: String, code: OutcomeCode = .other)
    case failed(reason: String, code: OutcomeCode = .other)
}

/// The saved form is the one the compiler wrote before codes existed (a key per case, the payload's labels inside),
/// plus a `code` beside each reason. A reason saved without one reads as `.other`.
extension JobState: Codable {
    private enum CaseKey: String, CodingKey {
        case queued, running, completed, keptAsIs, failed
    }

    private enum RunningKey: String, CodingKey { case progress }
    private enum CompletedKey: String, CodingKey { case outcome = "_0" }
    private enum ReasonKey: String, CodingKey { case reason, code }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        if container.contains(.completed) {
            let inner = try container.nestedContainer(keyedBy: CompletedKey.self, forKey: .completed)
            self = .completed(try inner.decode(JobOutcome.self, forKey: .outcome))
        } else if container.contains(.running) {
            let inner = try container.nestedContainer(keyedBy: RunningKey.self, forKey: .running)
            self = .running(progress: try inner.decode(Double.self, forKey: .progress))
        } else if container.contains(.keptAsIs) {
            let inner = try container.nestedContainer(keyedBy: ReasonKey.self, forKey: .keptAsIs)
            self = .keptAsIs(
                reason: try inner.decode(String.self, forKey: .reason),
                code: try inner.decodeIfPresent(OutcomeCode.self, forKey: .code) ?? .other)
        } else if container.contains(.failed) {
            let inner = try container.nestedContainer(keyedBy: ReasonKey.self, forKey: .failed)
            self = .failed(
                reason: try inner.decode(String.self, forKey: .reason),
                code: try inner.decodeIfPresent(OutcomeCode.self, forKey: .code) ?? .other)
        } else if container.contains(.queued) {
            self = .queued
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "No known job state"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .queued:
            _ = container.nestedContainer(keyedBy: CompletedKey.self, forKey: .queued)
        case .running(let progress):
            var inner = container.nestedContainer(keyedBy: RunningKey.self, forKey: .running)
            try inner.encode(progress, forKey: .progress)
        case .completed(let outcome):
            var inner = container.nestedContainer(keyedBy: CompletedKey.self, forKey: .completed)
            try inner.encode(outcome, forKey: .outcome)
        case .keptAsIs(let reason, let code):
            var inner = container.nestedContainer(keyedBy: ReasonKey.self, forKey: .keptAsIs)
            try inner.encode(reason, forKey: .reason)
            try inner.encode(code, forKey: .code)
        case .failed(let reason, let code):
            var inner = container.nestedContainer(keyedBy: ReasonKey.self, forKey: .failed)
            try inner.encode(reason, forKey: .reason)
            try inner.encode(code, forKey: .code)
        }
    }
}

public struct Job: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var toolID: String
    /// The file the job works on. A job of a tool whose videos aren't files has an address here instead (an
    /// `x-photos-asset:` URL): check `isFileURL` before using it as a path.
    public var source: URL
    public var sourceBookmark: Data
    /// Tool-encoded settings; only the tool's runner interprets these bytes.
    public var settings: Data
    public var state: JobState
    public var createdAt: Date
    /// What a running job is doing now when its runner says ("Downloading from iCloud…"); nil otherwise. Progress
    /// restarts from 0 in each phase.
    public var phase: String?

    public init(
        id: UUID = UUID(),
        toolID: String,
        source: URL,
        sourceBookmark: Data,
        settings: Data,
        state: JobState = .queued,
        createdAt: Date = Date(),
        phase: String? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.source = source
        self.sourceBookmark = sourceBookmark
        self.settings = settings
        self.state = state
        self.createdAt = createdAt
        self.phase = phase
    }

    /// The file the job worked on: the one its finished run read when that is known, else its recorded path.
    public var sourceUsed: URL {
        if case .completed(let outcome) = state, let source = outcome.source { return source }
        return source
    }
}

/// Runs one job. Returns `.completed` or `.keptAsIs`; throwing marks the job failed.
public protocol JobRunner: Sendable {
    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState

    /// Like `run(_:progress:)`, for a run with phases of its own (a download, then a conversion): `phase` says
    /// which one is under way, and `progress` then counts that phase from 0 to 1. The queue calls this one. A
    /// runner without phases needn't implement it.
    func run(
        _ job: Job, progress: @escaping @Sendable (Double) -> Void, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState
}

extension JobRunner {
    public func run(
        _ job: Job, progress: @escaping @Sendable (Double) -> Void, phase: @escaping @Sendable (String?) -> Void
    ) async throws -> JobState {
        try await run(job, progress: progress)
    }
}
