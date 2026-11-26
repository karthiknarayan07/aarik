import AppCore
import AppUI
import Convert
import Foundation
import LocalLibrary
import PhotosLibrary

/// Remembers when each running job was first seen and how far along it was, to estimate the time it has left.
/// A value type so the estimate is tested without a view.
struct ProgressTimeline: Equatable {
    private struct Sample: Equatable {
        var date: Date
        var progress: Double
    }

    private var first: [UUID: Sample] = [:]
    private var latest: [UUID: Sample] = [:]

    /// Seconds of history needed before an estimate is shown.
    static let minimumElapsed: TimeInterval = 3
    /// Progress gained before an estimate is shown.
    static let minimumGain = 0.02

    /// Records the running jobs' progress; a job that stopped running is forgotten, and one whose progress went
    /// backwards (a new phase) starts over.
    mutating func observe(_ jobs: [Job], now: Date = Date()) {
        var running: Set<UUID> = []
        for job in jobs {
            guard case .running(let progress) = job.state else { continue }
            running.insert(job.id)
            let sample = Sample(date: now, progress: progress)
            if let start = first[job.id], progress >= start.progress {
                latest[job.id] = sample
            } else {
                first[job.id] = sample
                latest[job.id] = sample
            }
        }
        first = first.filter { running.contains($0.key) }
        latest = latest.filter { running.contains($0.key) }
    }

    /// Seconds a whole run of this job would take at the pace seen so far; nil until there is enough to tell.
    func fullDuration(for id: UUID) -> TimeInterval? {
        guard let start = first[id], let now = latest[id] else { return nil }
        let elapsed = now.date.timeIntervalSince(start.date)
        let gain = now.progress - start.progress
        guard elapsed >= Self.minimumElapsed, gain >= Self.minimumGain else { return nil }
        return elapsed / gain
    }

    /// Seconds this running job has left; nil until there is enough to tell.
    func remaining(for id: UUID) -> TimeInterval? {
        guard let full = fullDuration(for: id), let now = latest[id] else { return nil }
        return full * (1 - now.progress)
    }

    /// Seconds until the queue is empty: what the running jobs have left, plus the waiting ones at the pace of the
    /// running ones, spread over how many run at once. Nil until a running job has an estimate.
    func totalRemaining(running: [Job], waitingCount: Int) -> TimeInterval? {
        let fulls = running.compactMap { fullDuration(for: $0.id) }
        let lefts = running.compactMap { remaining(for: $0.id) }
        guard !fulls.isEmpty, !lefts.isEmpty else { return nil }
        let average = fulls.reduce(0, +) / Double(fulls.count)
        let parallel = Double(max(1, running.count))
        return (lefts.max() ?? 0) + Double(waitingCount) * average / parallel
    }
}

/// How a time left is worded.
enum TimeLeftText {
    /// "Less than a minute", "About 5 min", "About 1 hr 20 min".
    static func string(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "Less than a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "About \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "About \(hours) hr" : "About \(hours) hr \(rest) min"
    }
}

/// The size a job starts from and the size it is expected to end at, for the queue's before → after.
struct QueueSizes: Equatable {
    var before: Int64
    var after: Int64?

    /// "1.4 GB → about 540 MB", or just the size when no estimate exists.
    var text: String {
        guard let after else { return ByteFormat.string(before) }
        return "\(ByteFormat.string(before)) → about \(ByteFormat.string(after))"
    }

    /// The sizes for a job from the library item it was added from; nil when the item isn't loaded.
    static func sizes(for job: Job, in items: [LibraryItem]) -> QueueSizes? {
        let item: LibraryItem?
        if let identifier = PhotoAssetURL.identifier(from: job.source) {
            item = items.first { $0.source == .photos(identifier) }
        } else {
            item = items.first { $0.fileURL == job.source }
        }
        guard let item, item.byteSize > 0 else { return nil }
        guard let settings = try? JSONDecoder().decode(ConvertJobSettings.self, from: job.settings) else {
            return QueueSizes(before: item.byteSize, after: nil)
        }
        let decision = SavingsCalculator.decision(
            byteSize: item.byteSize, inventory: item.inventory, kind: settings.kind, preset: settings.preset,
            custom: settings.custom)
        guard case .convert(_, let estimate, _) = decision else {
            return QueueSizes(before: item.byteSize, after: nil)
        }
        return QueueSizes(before: item.byteSize, after: estimate)
    }
}
