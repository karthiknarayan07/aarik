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
    public var warnings: [String]

    public init(
        output: URL,
        bytesBefore: Int64,
        bytesAfter: Int64,
        report: MetadataReport,
        replacedOriginal: Bool,
        warnings: [String] = []
    ) {
        self.output = output
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.report = report
        self.replacedOriginal = replacedOriginal
        self.warnings = warnings
    }

    /// Reads outcomes saved before `warnings` existed as having none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try container.decode(URL.self, forKey: .output)
        bytesBefore = try container.decode(Int64.self, forKey: .bytesBefore)
        bytesAfter = try container.decode(Int64.self, forKey: .bytesAfter)
        report = try container.decode(MetadataReport.self, forKey: .report)
        replacedOriginal = try container.decode(Bool.self, forKey: .replacedOriginal)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    /// Nothing unexpected was lost or changed, and a requested Replace happened.
    public var isVerified: Bool { warnings.isEmpty }

    /// Bytes freed; never negative.
    public var savedBytes: Int64 { max(0, bytesBefore - bytesAfter) }
}

public enum JobState: Codable, Sendable, Equatable {
    case queued
    case running(progress: Double)
    case completed(JobOutcome)
    case keptAsIs(reason: String)
    case failed(reason: String)
}

public struct Job: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var toolID: String
    public var source: URL
    public var sourceBookmark: Data
    /// Tool-encoded settings; only the tool's runner interprets these bytes.
    public var settings: Data
    public var state: JobState
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        toolID: String,
        source: URL,
        sourceBookmark: Data,
        settings: Data,
        state: JobState = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolID = toolID
        self.source = source
        self.sourceBookmark = sourceBookmark
        self.settings = settings
        self.state = state
        self.createdAt = createdAt
    }
}

/// Runs one job. Returns `.completed` or `.keptAsIs`; throwing marks the job failed.
public protocol JobRunner: Sendable {
    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState
}
