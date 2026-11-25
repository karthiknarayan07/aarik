import Foundation
import Synchronization

/// How one job of a run ended, kept so removing the job from the queue doesn't change the run's tally.
public struct QuickRunResult: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case converted, keptAsIs, failed }

    public let kind: Kind
    public let savedBytes: Int64
    /// The file, for a kept-as-is job (reviewed later).
    public let source: URL

    public init(kind: Kind, savedBytes: Int64 = 0, source: URL) {
        self.kind = kind
        self.savedBytes = savedBytes
        self.source = source
    }
}

/// One quick run as remembered between launches.
public struct QuickRunRecord: Codable, Sendable, Equatable, Identifiable {
    public let runID: UUID
    public let createdAt: Date
    public var jobIDs: [UUID]
    public var skipped: [QuickRunSkip]
    public let notes: [String]
    /// How the finished jobs ended, by job ID.
    public var results: [UUID: QuickRunResult] = [:]
    /// Set once the run's notification was handed over, so it is never posted twice.
    public var notified = false

    public var id: UUID { runID }

    /// Reads records saved before `results` or `notified` existed as having none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(UUID.self, forKey: .runID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        jobIDs = try container.decode([UUID].self, forKey: .jobIDs)
        skipped = try container.decode([QuickRunSkip].self, forKey: .skipped)
        notes = try container.decode([String].self, forKey: .notes)
        results = try container.decodeIfPresent([UUID: QuickRunResult].self, forKey: .results) ?? [:]
        notified = try container.decodeIfPresent(Bool.self, forKey: .notified) ?? false
    }

    public init(runID: UUID, createdAt: Date, jobIDs: [UUID], skipped: [QuickRunSkip], notes: [String]) {
        self.runID = runID
        self.createdAt = createdAt
        self.jobIDs = jobIDs
        self.skipped = skipped
        self.notes = notes
    }
}

/// The quick runs of the last week: their job IDs and skipped files, kept as JSON so a notification clicked after
/// a relaunch can still show what was skipped.
public final class QuickRunStore: Sendable {
    public static let retention: TimeInterval = 7 * 86_400

    private struct State {
        var records: [QuickRunRecord]
        /// Every job ID of every record, kept in step so the queue's updates can test membership cheaply.
        var jobIDs: Set<UUID>

        init(_ records: [QuickRunRecord]) {
            self.records = records
            jobIDs = Set(records.flatMap(\.jobIDs))
        }
    }

    private let fileURL: URL
    private let state: Mutex<State>

    /// Reads the file (none or unreadable means no runs) and drops runs older than seven days.
    public init(fileURL: URL, now: Date = Date()) {
        self.fileURL = fileURL
        let loaded =
            (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([QuickRunRecord].self, from: $0) }
            ?? []
        let kept = loaded.filter { now.timeIntervalSince($0.createdAt) <= Self.retention }
        self.state = Mutex(State(kept))
        if kept.count != loaded.count { save(kept) }
    }

    public var runs: [QuickRunRecord] { state.withLock { $0.records } }

    public func run(_ id: UUID) -> QuickRunRecord? { state.withLock { $0.records.first { $0.runID == id } } }

    /// Every job ID of every remembered run.
    public var jobIDs: Set<UUID> { state.withLock { $0.jobIDs } }

    public func add(_ record: QuickRunRecord) {
        state.withLock {
            $0.records.append(record)
            $0.jobIDs.formUnion(record.jobIDs)
            save($0.records)
        }
    }

    /// Changes a remembered run in place; ignored for an unknown run.
    public func update(_ id: UUID, _ change: (inout QuickRunRecord) -> Void) {
        state.withLock {
            guard let index = $0.records.firstIndex(where: { $0.runID == id }) else { return }
            change(&$0.records[index])
            $0.jobIDs = Set($0.records.flatMap(\.jobIDs))
            save($0.records)
        }
    }

    /// True the first time for a run, false after; false for an unknown run.
    public func markNotified(_ id: UUID) -> Bool {
        state.withLock {
            guard let index = $0.records.firstIndex(where: { $0.runID == id }), !$0.records[index].notified else {
                return false
            }
            $0.records[index].notified = true
            save($0.records)
            return true
        }
    }

    private func save(_ records: [QuickRunRecord]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: fileURL, options: .atomic) }
    }
}
