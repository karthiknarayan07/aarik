import AppCore
import AppUI
import DownscaleVideo
import Foundation
import MediaEngine

/// Converts files in the background with the saved defaults, without asking anything or showing a window.
///
/// - A file whose conversion would lose metadata is skipped, never queued (the loss policy is skip). So is a file
///   the planner would keep as is, with its reason.
/// - Replace is never used: with Replace saved, files are saved next to the originals and the run says so.
/// - Everything goes into the one shared queue. When every job of a run is done, one notification is posted.
public actor QuickRun {
    private let queue: any QuickRunQueue
    private let store: QuickRunStore
    private let notifier: any QuickRunNotifying
    private let inspector: any QuickRunInspecting
    private let settings: @Sendable () async -> QuickRunSettings
    private let now: @Sendable () -> Date
    private var watcher: Task<Void, Never>?
    /// Runs being set up: their jobs are on the way into the queue, so they can't be judged finished yet.
    private var starting: Set<UUID> = []

    public init(
        queue: any QuickRunQueue, store: QuickRunStore, notifier: any QuickRunNotifying,
        inspector: any QuickRunInspecting = MediaQuickRunInspector(),
        settings: @escaping @Sendable () async -> QuickRunSettings,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.queue = queue
        self.store = store
        self.notifier = notifier
        self.inspector = inspector
        self.settings = settings
        self.now = now
    }

    /// Starts watching the queue so runs finish with a notification, including runs left over from an earlier
    /// launch. Safe to call more than once.
    public func start() {
        guard watcher == nil else { return }
        let queue = self.queue
        watcher = Task { [weak self] in
            for await _ in await queue.updates() {
                await self?.refresh()
            }
        }
    }

    /// Plans `urls` with the saved settings (or `overrides`), queues what converts cleanly and remembers the run.
    public func run(urls: [URL], overrides: QuickRunOverrides?) async -> QuickRunReceipt {
        let saved = await settings()
        let preset = overrides?.preset ?? saved.preset
        let (destination, notes) = Self.destination(for: overrides?.saveLocation ?? saved.saveLocation)

        let unique = Self.unique(urls)
        let (accepted, skippedByPlan) = await plan(unique, preset: preset)
        let batch = JobFactory.makeJobs(
            for: accepted, settings: DownscaleJobSettings(preset: preset, saveTo: destination), losses: [:],
            now: now())
        // Remembered before the jobs exist in the queue, so the app never sees them as the window's own jobs, and
        // held back from `refresh` until the run is complete.
        let unreadable = batch.skipped.map { QuickRunSkip(url: $0, reason: Self.unreadable) }
        let runID = UUID()
        store.add(
            QuickRunRecord(
                runID: runID, createdAt: now(), jobIDs: batch.jobs.map(\.id), skipped: [], notes: notes))
        starting.insert(runID)
        let added = await queue.enqueue(batch.jobs)
        let addedSources = Set(added.map(\.source))
        let duplicates = batch.jobs.filter { !addedSources.contains($0.source) }.map {
            QuickRunSkip(url: $0.source, reason: "Already in the queue")
        }
        let skipped = Self.inOrder(unique, skippedByPlan + unreadable + duplicates)
        store.update(runID) {
            $0.jobIDs = added.map(\.id)
            $0.skipped = skipped
        }
        starting.remove(runID)
        if saved.startsQueue, !added.isEmpty { await queue.resume() }
        // A run with nothing queued is done now; one whose jobs already finished is too.
        await refresh()
        return QuickRunReceipt(runID: runID, queuedJobIDs: added.map(\.id), skipped: skipped, notes: notes)
    }

    /// Posts the notification of every run whose jobs have all finished and that wasn't announced yet. The queue's
    /// current jobs decide, not a snapshot that may be older than a run just recorded. How each job ended is kept
    /// in the record, so removing finished jobs from the queue doesn't change the tally.
    public func refresh() async {
        let jobs = Dictionary(await queue.jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in store.runs where !record.notified && !starting.contains(record.runID) {
            var results = record.results
            var pending = false
            for id in record.jobIDs where results[id] == nil {
                guard let job = jobs[id] else { continue }
                if let result = Self.result(of: job) {
                    results[id] = result
                } else {
                    pending = true
                }
            }
            if results != record.results { store.update(record.runID) { $0.results = results } }
            if pending { continue }
            guard store.markNotified(record.runID) else { continue }
            // Every job removed by hand before it finished and nothing skipped: nothing to report.
            if results.isEmpty, !record.jobIDs.isEmpty, record.skipped.isEmpty { continue }
            var done = record
            done.results = results
            await notifier.post(Self.notice(for: done))
        }
    }

    /// The files to review for a run: the ones skipped up front, and the ones whose job ended up kept as is.
    public func skippedURLs(runID: UUID) async -> [URL] {
        await refresh()
        guard let record = store.run(runID) else { return [] }
        let keptAsIs = record.jobIDs.compactMap { record.results[$0] }.filter { $0.kind == .keptAsIs }.map(\.source)
        return record.skipped.map(\.url) + keptAsIs
    }

    private static func result(of job: Job) -> QuickRunResult? {
        switch job.state {
        case .completed(let outcome):
            QuickRunResult(kind: .converted, savedBytes: outcome.savedBytes, source: job.source)
        case .keptAsIs: QuickRunResult(kind: .keptAsIs, source: job.source)
        case .failed: QuickRunResult(kind: .failed, source: job.source)
        case .queued, .running: nil
        }
    }

    // MARK: - Planning

    static let unreadable = "Couldn't be read as a video"

    /// Splits `urls` into the ones to convert and the ones to skip, with the reason.
    private func plan(_ urls: [URL], preset: Preset) async -> ([(url: URL, preset: Preset)], [QuickRunSkip]) {
        var sources: [(id: URL, source: SavingsCalculator.Source)] = []
        var skipped: [QuickRunSkip] = []
        for url in urls {
            if let source = await inspector.inspect(url) {
                sources.append((url, (source.byteSize, source.inventory)))
            } else {
                skipped.append(QuickRunSkip(url: url, reason: Self.unreadable))
            }
        }
        let fallbacks = await LossCheck.quickTimeFallbacks(among: sources.map { (id: $0.id, url: $0.id) })
        let losses = Dictionary(
            uniqueKeysWithValues: LossCheck.losses(
                for: sources.map { (id: $0.id, source: $0.source, preset: preset) }, quickTimeFallbacks: fallbacks
            ).map { ($0.id, $0) })
        var accepted: [(url: URL, preset: Preset)] = []
        for (url, source) in sources {
            let decision = SavingsCalculator.decision(
                byteSize: source.byteSize, inventory: source.inventory, preset: preset,
                fallsBackToQuickTime: fallbacks.contains(url))
            switch decision {
            case .keptAsIs(let reason):
                skipped.append(QuickRunSkip(url: url, reason: reason))
            case .convert:
                if let loss = losses[url] {
                    skipped.append(QuickRunSkip(url: url, reason: "Would lose " + loss.lost.joined(separator: ", ")))
                } else {
                    accepted.append((url, preset))
                }
            }
        }
        return (accepted, skipped)
    }

    /// Replace needs the window's confirmation, so a quick run saves next to the original instead; so does a
    /// folder that can't be resolved.
    private static func destination(for location: SaveLocation) -> (SaveDestination, [String]) {
        switch location.choice {
        case .replace:
            return (
                .nextToOriginal,
                ["Saved next to the originals: replacing originals needs your confirmation in the app."]
            )
        case .folder:
            if let destination = location.destination { return (destination, []) }
            return (.nextToOriginal, ["Saved next to the originals: the Save to folder isn't available."])
        case .nextToOriginal:
            return (.nextToOriginal, [])
        }
    }

    /// The same file twice (by standardized path) counts once.
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Skips sorted as the files were given.
    private static func inOrder(_ urls: [URL], _ skips: [QuickRunSkip]) -> [QuickRunSkip] {
        let position = Dictionary(
            urls.enumerated().map { ($1.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        return skips.enumerated().sorted {
            (position[$0.element.url.standardizedFileURL.path] ?? 0, $0.offset)
                < (position[$1.element.url.standardizedFileURL.path] ?? 0, $1.offset)
        }.map(\.element)
    }

    // MARK: - Notification

    static func notice(for record: QuickRunRecord) -> QuickRunNotice {
        let results = record.results.values
        let converted = results.filter { $0.kind == .converted }.count
        let saved = results.reduce(Int64(0)) { $0 + $1.savedBytes }
        let skipped = record.skipped.count + results.filter { $0.kind == .keptAsIs }.count
        let failed = results.filter { $0.kind == .failed }.count
        var sentences: [String] = []
        if converted > 0 { sentences.append("\(converted) converted, saved \(ByteFormat.string(saved)).") }
        if skipped > 0 { sentences.append("\(skipped) skipped.") }
        if failed > 0 { sentences.append("\(failed) failed.") }
        if sentences.isEmpty { sentences.append("Nothing was converted.") }
        sentences += record.notes
        return QuickRunNotice(runID: record.runID, title: "Quick run finished", body: sentences.joined(separator: " "))
    }
}

/// Reads real files with the metadata inspector.
public struct MediaQuickRunInspector: QuickRunInspecting {
    public init() {}

    public func inspect(_ url: URL) async -> QuickRunSource? {
        guard let inventory = try? await MediaInspector().inventory(of: url),
            inventory["video.dimensions"] != nil,
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return QuickRunSource(byteSize: Int64(size), inventory: inventory)
    }
}
