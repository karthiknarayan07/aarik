import Foundation
import Testing

@testable import AppCore

// MARK: - Helpers

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SharedQueueTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeJob(tool: String, name: String, settings: Data = Data()) -> Job {
    Job(
        toolID: tool, source: URL(fileURLWithPath: "/tmp/\(name).mov"), sourceBookmark: Data(), settings: settings)
}

private func waitUntil(_ queue: JobQueue, _ predicate: @Sendable ([Job]) -> Bool) async {
    for await jobs in await queue.updates() where predicate(jobs) { return }
}

/// Finishes every job at once and remembers which jobs it was given.
private final class RecordingRunner: JobRunner {
    private let ran = Locked<[String]>([])

    var ranNames: [String] { ran.value }

    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        ran.mutate { $0.append(job.source.deletingPathExtension().lastPathComponent) }
        return .keptAsIs(reason: "recorded", code: .other)
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

private struct FakeTool: Tool {
    let id: String
    let platforms: ToolPlatforms
    let runner: RecordingRunner

    var title: String { "Fake" }
    var systemImage: String { "star" }
    var jobKinds: [JobKind] { [JobKind(rawValue: id)] }

    func accepts(_ input: MediaInput) -> Bool {
        if case .file(let url) = input { return url.pathExtension == "mov" }
        return false
    }

    func runner(for kind: JobKind) -> (any JobRunner)? { kind == JobKind(rawValue: id) ? runner : nil }
}

// MARK: - The shared queue

@Suite struct SharedQueueTests {
    @Test func jobsRouteToTheirToolsRunner() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FakeTool(id: "tool-a", platforms: .all, runner: RecordingRunner())
        let second = FakeTool(id: "tool-b", platforms: .all, runner: RecordingRunner())
        let queue = JobQueue(store: JobStore(directory: directory), runners: [:], startPaused: true)
        for tool in [first, second] {
            for kind in tool.jobKinds {
                if let runner = tool.runner(for: kind) { queue.register(runner, forToolID: kind.toolID) }
            }
        }
        #expect(queue.registeredToolIDs == ["tool-a", "tool-b"])
        await queue.enqueue([
            makeJob(tool: "tool-a", name: "one"), makeJob(tool: "tool-b", name: "two"),
            makeJob(tool: "tool-a", name: "three"),
        ])
        await queue.resume()
        await waitUntil(queue) { $0.count == 3 && !$0.contains { $0.state.isPending } }
        #expect(first.runner.ranNames == ["one", "three"])
        #expect(second.runner.ranNames == ["two"])
    }

    @Test func unknownToolJobsAreKeptNotDropped() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A job another build saved for a tool this build doesn't have, with settings only that tool can read.
        let payload = Data(#"{"future":"payload","n":7}"#.utf8)
        let future = makeJob(tool: "future-tool", name: "later", settings: payload)
        let own = makeJob(tool: "tool-a", name: "now")
        let store = JobStore(directory: directory)
        try store.save([future, own])

        let runner = RecordingRunner()
        let queue = JobQueue(store: store, runners: ["tool-a": runner])
        // Loading keeps both jobs, in order, untouched.
        #expect(await queue.jobs.map(\.id) == [future.id, own.id])
        await queue.resume()
        await waitUntil(queue) { $0.count == 2 && !$0.contains { $0.state.isPending } }
        await queue.shutdown()

        // The unknown job didn't run and didn't get another tool's runner. It is still saved, with its tool and
        // settings as they were; only its state says no tool in this build could run it.
        #expect(runner.ranNames == ["now"])
        let saved = store.load()
        let kept = try #require(saved.first { $0.id == future.id })
        #expect(kept.toolID == "future-tool")
        #expect(kept.settings == payload)
        #expect(kept.source == future.source)
        #expect(kept.state == .failed(reason: "No tool can run this job", code: .noToolForJob))

        // Once the tool is there (a later build), the same saved job can be retried and runs.
        let later = RecordingRunner()
        let relaunched = JobQueue(store: store, runners: ["future-tool": later])
        await relaunched.retry(future.id)
        await waitUntil(relaunched) { $0.first { $0.id == future.id }?.state == .keptAsIs(reason: "recorded") }
        #expect(later.ranNames == ["later"])
    }

    @Test func aRunnerRegisteredLaterReplacesTheEarlierOne() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let early = RecordingRunner()
        let late = RecordingRunner()
        let queue = JobQueue(store: JobStore(directory: directory), runners: ["tool-a": early])
        queue.register(late, forToolID: "tool-a")
        await queue.enqueue([makeJob(tool: "tool-a", name: "x")])
        await waitUntil(queue) { $0.count == 1 && !$0.contains { $0.state.isPending } }
        #expect(early.ranNames.isEmpty)
        #expect(late.ranNames == ["x"])
    }
}

// MARK: - Tool

@Suite struct ToolCoreTests {
    @Test func aToolSaysWhatItAcceptsAndWhichRunnerIsItsOwn() {
        let tool = FakeTool(id: "tool-a", platforms: .all, runner: RecordingRunner())
        #expect(tool.accepts(.file(URL(filePath: "/tmp/clip.mov"))))
        #expect(!tool.accepts(.file(URL(filePath: "/tmp/photo.heic"))))
        #expect(!tool.accepts(.photosAsset(identifier: "abc", isVideo: true)))
        #expect(tool.runner(for: "tool-a") != nil)
        #expect(tool.runner(for: "tool-b") == nil)
    }

    @Test func aJobKindIsTheToolIDEveryJobCarries() {
        #expect(JobKind(rawValue: "downscale-video").toolID == "downscale-video")
        #expect(JobKind(stringLiteral: "x") == "x")
    }

    @Test func theRegistryKeepsOnlyToolsThatIncludeThePlatform() {
        let both = FakeTool(id: "both", platforms: [.macOS, .iOS], runner: RecordingRunner())
        let mac = FakeTool(id: "mac", platforms: .macOS, runner: RecordingRunner())
        let phone = FakeTool(id: "phone", platforms: .iOS, runner: RecordingRunner())
        #expect(ToolRegistry.tools(for: .macOS, from: [both, phone, mac]).map(\.id) == ["both", "mac"])
        #expect(ToolRegistry.tools(for: .iOS, from: [both, phone, mac]).map(\.id) == ["both", "phone"])
        #expect(ToolRegistry.tools(for: .macOS, from: [phone]).isEmpty)
    }

    @Test func allCoversBothPlatforms() {
        #expect(ToolPlatforms.all == [.macOS, .iOS])
    }
}
