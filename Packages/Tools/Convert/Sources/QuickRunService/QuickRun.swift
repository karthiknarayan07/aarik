import AppCore
import AppUI
import Convert
import Foundation
import MediaEngine
import PhotosLibrary

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
    public func run(
        urls: [URL], overrides: QuickRunOverrides?, origin: QuickRunOrigin = .background
    ) async -> QuickRunReceipt {
        let saved = await settings()
        let preset = overrides?.preset ?? saved.preset
        let (destination, notes) = Self.destination(for: overrides?.saveLocation ?? saved.saveLocation)

        let unique = Self.unique(urls)
        let (accepted, skippedByPlan) = await plan(unique, preset: preset, codec: overrides?.codec)
        var jobs: [Job] = []
        var unreadable: [QuickRunSkip] = []
        for file in accepted {
            let batch = JobFactory.makeJobs(
                for: [(url: file.url, preset: preset)],
                settings: ConvertJobSettings(preset: preset, saveTo: destination, custom: file.custom),
                losses: [:], now: now())
            jobs += batch.jobs
            unreadable += batch.skipped.map { QuickRunSkip(url: $0, reason: Self.unreadable) }
        }
        return await enqueue(
            jobs, order: unique, skipped: skippedByPlan + unreadable, notes: notes, startsQueue: saved.startsQueue,
            origin: origin)
    }

    /// Plans Photos videos like `run(urls:overrides:)` plans files. Nothing is downloaded: what a video would lose
    /// comes from what Photos says about it (`PhotosLossCheck`), and the run keeps the original as is when it finds
    /// more. Copies go to Photos as new videos, or to the folder in `overrides`; never Replace.
    public func runPhotos(
        _ videos: [QuickRunPhotoVideo], overrides: QuickRunOverrides?, origin: QuickRunOrigin = .background
    ) async -> QuickRunReceipt {
        let saved = await settings()
        let preset = overrides?.preset ?? saved.preset
        var seen = Set<String>()
        let unique = videos.filter { seen.insert($0.assetID).inserted }
        let destination: PhotosDestination
        if let location = overrides?.saveLocation, location.choice == .folder, let bookmark = location.folderBookmark {
            destination = .folder(bookmark: bookmark)
        } else {
            destination = .newAsset
        }
        var skipped: [QuickRunSkip] = []
        var accepted: [QuickRunPhotoVideo] = []
        for video in unique {
            let lost = PhotosLossCheck.lostNames(isCinematic: video.isCinematic, isHDR: video.isHDR, custom: nil)
            if lost.isEmpty {
                accepted.append(video)
            } else {
                skipped.append(
                    QuickRunSkip(
                        url: PhotoAssetURL.url(for: video.assetID), reason: "Would lose " + lost.joined(separator: ", ")
                    ))
            }
        }
        let jobs = PhotosJobFactory.makeJobs(
            for: accepted.map { (assetID: $0.assetID, name: $0.name, preset: preset) },
            settings: ConvertJobSettings(preset: preset, saveTo: .nextToOriginal), destination: destination,
            lost: [:], now: now())
        // The saved Save to is for files; say so when it isn't what the copies got.
        var notes: [String] = []
        if overrides?.saveLocation == nil {
            switch saved.saveLocation.choice {
            case .nextToOriginal, .documents: break
            case .folder: notes.append("Saved as new videos in Photos: the Save to folder is for files.")
            case .replace:
                notes.append("Saved as new videos in Photos: replacing originals needs your confirmation in the app.")
            }
        }
        return await enqueue(
            jobs, order: unique.map { PhotoAssetURL.url(for: $0.assetID) }, skipped: skipped, notes: notes,
            startsQueue: saved.startsQueue, origin: origin)
    }

    /// Remembers the run, adds its jobs to the queue (skipping what is already in it) and starts the queue.
    private func enqueue(
        _ jobs: [Job], order: [URL], skipped skippedByPlan: [QuickRunSkip], notes: [String], startsQueue: Bool,
        origin: QuickRunOrigin
    ) async -> QuickRunReceipt {
        // Remembered before the jobs exist in the queue, so the app never sees them as the window's own jobs, and
        // held back from `refresh` until the run is complete.
        let runID = UUID()
        store.add(
            QuickRunRecord(
                runID: runID, createdAt: now(), jobIDs: jobs.map(\.id), skipped: [], notes: notes, origin: origin))
        starting.insert(runID)
        let added = await queue.enqueue(jobs)
        let addedSources = Set(added.map(\.source))
        let duplicates = jobs.filter { !addedSources.contains($0.source) }.map {
            QuickRunSkip(url: $0.source, reason: "Already in the queue")
        }
        let skipped = Self.inOrder(order, skippedByPlan + duplicates)
        store.update(runID) {
            $0.jobIDs = added.map(\.id)
            $0.skipped = skipped
        }
        starting.remove(runID)
        if startsQueue, !added.isEmpty { await queue.resume() }
        // A run with nothing queued is done now; one whose jobs already finished is too.
        await refresh()
        return QuickRunReceipt(
            runID: runID, queuedJobIDs: added.map(\.id), skipped: skipped, notes: notes, startedQueue: startsQueue)
    }

    /// Waits until every job of the run has ended (a job removed from the queue counts as ended), or until it is
    /// clear that waiting would not end: the queue is paused with none of the run's jobs running (checked on every
    /// queue change and every `pollInterval`, because pausing is not a queue change), or the queue stopped.
    public func wait(for receipt: QuickRunReceipt, pollInterval: Duration = .seconds(1)) async -> QuickRunWait {
        let wanted = receipt.queuedJobIDs
        guard !wanted.isEmpty else { return .finished(outputs: [], converted: 0) }
        let queue = self.queue
        return await withTaskGroup(of: QuickRunWait?.self) { group in
            group.addTask {
                for await jobs in await queue.updates() {
                    if let done = await Self.decide(wanted, jobs: jobs, queue: queue) { return done }
                }
                return .interrupted
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: pollInterval)
                    if Task.isCancelled { break }
                    if let done = await Self.decide(wanted, jobs: await queue.jobs, queue: queue) { return done }
                }
                return .interrupted
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .interrupted
        }
    }

    private static func decide(_ wanted: [UUID], jobs: [Job], queue: any QuickRunQueue) async -> QuickRunWait? {
        let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let present = wanted.compactMap { byID[$0] }
        if !present.contains(where: { result(of: $0) == nil }) {
            let outputs = present.compactMap { job -> URL? in
                guard job.source.isFileURL, case .completed(let outcome) = job.state else { return nil }
                return outcome.output
            }
            let converted = present.filter { job in
                if case .completed = job.state { true } else { false }
            }.count
            return .finished(outputs: outputs, converted: converted)
        }
        let running = present.contains { job in
            if case .running = job.state { true } else { false }
        }
        if !running, await queue.isPaused() { return .paused }
        return nil
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

    /// A file to convert, with the custom spec its format needs (nil: the preset's own).
    struct Accepted {
        let url: URL
        let custom: DownscaleSpec?
    }

    /// Splits `urls` into the ones to convert and the ones to skip, with the reason. With H.264 asked for, each
    /// file's spec is its preset's with the codec changed, so an HDR clip is judged by what H.264 drops.
    private func plan(_ urls: [URL], preset: Preset, codec: VideoCodec?) async -> ([Accepted], [QuickRunSkip]) {
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
        var accepted: [Accepted] = []
        for (url, source) in sources {
            let custom = Self.customSpec(for: source, preset: preset, codec: codec)
            let decision = SavingsCalculator.decision(
                byteSize: source.byteSize, inventory: source.inventory, preset: preset, custom: custom,
                fallsBackToQuickTime: fallbacks.contains(url))
            switch decision {
            case .keptAsIs(let reason, _):
                skipped.append(QuickRunSkip(url: url, reason: reason))
            case .convert:
                let loss = LossCheck.losses(
                    for: [(id: url, source: source)], preset: preset, custom: custom,
                    quickTimeFallbacks: fallbacks.intersection([url])
                ).first
                if let loss {
                    skipped.append(QuickRunSkip(url: url, reason: "Would lose " + loss.lost.joined(separator: ", ")))
                } else {
                    accepted.append(Accepted(url: url, custom: custom))
                }
            }
        }
        return (accepted, skipped)
    }

    /// The preset's spec for this file with the codec changed and the bit rate raised the way the Advanced Format
    /// picker does; nil when the codec is not changed (HEVC is what every preset produces).
    static func customSpec(
        for source: SavingsCalculator.Source, preset: Preset, codec: VideoCodec?
    ) -> DownscaleSpec? {
        guard codec == .h264Compatible else { return nil }
        var spec = preset.spec(for: source.inventory, byteSize: source.byteSize)
        spec.codec = .h264Compatible
        spec.averageBitRate = Int((Double(spec.averageBitRate) * AdvancedOptions.h264BitRateFactor).rounded())
        return spec
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
        case .documents:
            return (.documents, [])
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
            urls.enumerated().map { (key(of: $1), $0) }, uniquingKeysWith: { first, _ in first })
        return skips.enumerated().sorted {
            (position[key(of: $0.element.url)] ?? 0, $0.offset) < (position[key(of: $1.element.url)] ?? 0, $1.offset)
        }.map(\.element)
    }

    /// A file by its standardized path; a Photos address by itself.
    private static func key(of url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
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
        return QuickRunNotice(
            runID: record.runID, title: "Quick run finished", body: sentences.joined(separator: " "),
            origin: record.origin, tally: QuickRunTally(converted: converted, skipped: skipped, failed: failed))
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
