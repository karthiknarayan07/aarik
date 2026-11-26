import AppCore
import DownscaleVideo
import Foundation
import MediaEngine

@testable import QuickRunService

/// Videos that exist as empty files, inspected by a fake that returns prepared inventories.
struct QuickRunFixture {
    let directory: URL

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "quickrun-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(_ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    var storeURL: URL { directory.appending(path: "quick-runs.json") }

    // MARK: Sources

    private static func item(_ key: String, _ value: String, name: String? = nil) -> MetadataItem {
        MetadataItem(key: key, category: .video, displayName: name ?? key, value: value)
    }

    private static func inventory(size: String, extra: [MetadataItem] = []) -> MetadataInventory {
        MetadataInventory(
            items: [
                item("video.dimensions", size), item("video.frameRate", "30.00"), item("video.duration", "60000"),
                item("audio.0.format", "aac "),
            ] + extra)
    }

    /// 60 Mbps for 60 s.
    static let bigSize = Int64(60_000_000 * 60 / 8)

    /// A 4K clip that converts cleanly.
    static let clean = QuickRunSource(byteSize: bigSize, inventory: inventory(size: "3840x2160"))
    /// A 4K clip whose Cinematic depth data would be lost.
    static let lossy = QuickRunSource(
        byteSize: bigSize,
        inventory: inventory(
            size: "3840x2160",
            extra: [
                item("track.2.kind", "auxv/dish", name: "Track 3 kind"),
                item("trackmeta.2.com.apple.quicktime.x", "1", name: "Track 3 x"),
            ]))
    /// A 720p clip already below the balanced rate.
    static let small = QuickRunSource(
        byteSize: Int64(3_000_000 * 60 / 8), inventory: inventory(size: "1280x720"))
}

struct FakeInspector: QuickRunInspecting {
    var sources: [URL: QuickRunSource]

    func inspect(_ url: URL) async -> QuickRunSource? { sources[url] }
}

/// A queue that keeps its jobs in memory, with the same de-duplication as the real one, and finishes them on
/// command.
actor FakeQueue: QuickRunQueue {
    private(set) var items: [Job] = []
    private(set) var resumeCount = 0
    private var paused = false
    private var continuations: [AsyncStream<[Job]>.Continuation] = []

    var jobs: [Job] { items }

    func enqueue(_ jobs: [Job]) -> [Job] {
        var pending = Set(items.filter(\.state.isPending).map(\.source))
        let added = jobs.filter { pending.insert($0.source).inserted }
        items.append(contentsOf: added)
        publish()
        return added
    }

    func resume() {
        resumeCount += 1
        paused = false
    }

    func isPaused() -> Bool { paused }

    func setPaused(_ value: Bool) { paused = value }

    /// Ends every update stream, as a queue that shut down does.
    func stop() {
        for continuation in continuations { continuation.finish() }
        continuations = []
    }

    func updates() -> AsyncStream<[Job]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Job].self, bufferingPolicy: .bufferingNewest(1))
        continuations.append(continuation)
        continuation.yield(items)
        return stream
    }

    func finish(_ id: UUID, with state: JobState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        publish()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        publish()
    }

    func completeAll(saving saved: Int64 = 1000) {
        for job in items where job.state.isPending {
            finish(job.id, with: .completed(Self.outcome(for: job, saving: saved)))
        }
    }

    static func outcome(for job: Job, saving saved: Int64) -> JobOutcome {
        JobOutcome(
            output: job.source.deletingLastPathComponent().appending(path: "out.mov"), bytesBefore: saved + 10,
            bytesAfter: 10, report: MetadataReport(), replacedOriginal: false)
    }

    private func publish() {
        for continuation in continuations { continuation.yield(items) }
    }
}

actor FakeNotifier: QuickRunNotifying {
    private(set) var notices: [QuickRunNotice] = []

    func post(_ notice: QuickRunNotice) { notices.append(notice) }
}

/// A clock the test moves.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.date = date }

    var now: Date { lock.withLock { date } }

    func advance(days: Double) { lock.withLock { date = date.addingTimeInterval(days * 86_400) } }
}
