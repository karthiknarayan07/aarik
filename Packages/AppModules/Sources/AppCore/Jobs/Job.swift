import Foundation

/// What a finished conversion produced.
public struct JobOutcome: Codable, Sendable, Equatable {
    public var output: URL
    public var bytesBefore: Int64
    public var bytesAfter: Int64
    public var report: MetadataReport
    public var replacedOriginal: Bool

    public init(
        output: URL,
        bytesBefore: Int64,
        bytesAfter: Int64,
        report: MetadataReport,
        replacedOriginal: Bool
    ) {
        self.output = output
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.report = report
        self.replacedOriginal = replacedOriginal
    }
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
