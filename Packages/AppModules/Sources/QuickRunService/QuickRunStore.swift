import Foundation
import Synchronization

/// One quick run as remembered between launches.
public struct QuickRunRecord: Codable, Sendable, Equatable, Identifiable {
    public let runID: UUID
    public let createdAt: Date
    public let jobIDs: [UUID]
    public let skipped: [QuickRunSkip]
    public let notes: [String]
    /// Set once the run's notification was handed over, so it is never posted twice.
    public var notified = false

    public var id: UUID { runID }

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

    private let fileURL: URL
    private let records: Mutex<[QuickRunRecord]>

    /// Reads the file (none or unreadable means no runs) and drops runs older than seven days.
    public init(fileURL: URL, now: Date = Date()) {
        self.fileURL = fileURL
        let loaded =
            (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([QuickRunRecord].self, from: $0) }
            ?? []
        let kept = loaded.filter { now.timeIntervalSince($0.createdAt) <= Self.retention }
        self.records = Mutex(kept)
        if kept.count != loaded.count { save(kept) }
    }

    public var runs: [QuickRunRecord] { records.withLock { $0 } }

    public func run(_ id: UUID) -> QuickRunRecord? { records.withLock { $0.first { $0.runID == id } } }

    /// Every job ID of every remembered run.
    public var jobIDs: Set<UUID> { records.withLock { Set($0.flatMap(\.jobIDs)) } }

    public func add(_ record: QuickRunRecord) {
        records.withLock {
            $0.append(record)
            save($0)
        }
    }

    /// True the first time for a run, false after; false for an unknown run.
    public func markNotified(_ id: UUID) -> Bool {
        records.withLock {
            guard let index = $0.firstIndex(where: { $0.runID == id }), !$0[index].notified else { return false }
            $0[index].notified = true
            save($0)
            return true
        }
    }

    private func save(_ records: [QuickRunRecord]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: fileURL, options: .atomic) }
    }
}
