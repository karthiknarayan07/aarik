import AppCore
import Foundation
import PhotosLibrary
import Testing

@testable import AppServices

private func makeDirectory() throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "services-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "AppServicesTests-\(UUID().uuidString)")!
}

@MainActor
private func makeServices(
    directory: URL, defaults: UserDefaults = isolatedDefaults()
) -> AppServices {
    AppServices(directory: directory, defaults: defaults, photoStore: FakePhotoStore())
}

private func job(tool: String, name: String) -> Job {
    Job(toolID: tool, source: URL(filePath: "/tmp/\(name).mov"), sourceBookmark: Data(), settings: Data())
}

/// Finishes a job as soon as it starts and says what it ran.
private struct InstantRunner: JobRunner {
    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        .keptAsIs(reason: "done", code: .other)
    }
}

private struct InstantTool: Tool {
    let id = "instant"
    var title: String { "Instant" }
    var systemImage: String { "bolt" }
    var jobKinds: [JobKind] { ["instant", "instant-photos"] }
    func runner(for kind: JobKind) -> (any JobRunner)? { kind == "instant-photos" ? nil : InstantRunner() }
}

@MainActor
@Suite struct AppServicesTests {
    @Test func aRegisteredToolsJobsRunAndAreMirroredWithTheirActivity() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = makeServices(directory: directory)
        services.register(InstantTool())
        // Only the kinds that have a runner are registered.
        #expect(services.queue.registeredToolIDs == ["instant"])
        await services.start()
        await services.queue.enqueue([job(tool: "instant", name: "a"), job(tool: "instant", name: "b")])
        for await jobs in await services.queue.updates() where jobs.count == 2 && !jobs.contains(where: { $0.state.isPending }) {
            break
        }
        // The mirror follows the queue's stream; wait for the main actor to take the last snapshot.
        while services.jobs.count < 2 || services.jobs.contains(where: { $0.state.isPending }) {
            await Task.yield()
        }
        #expect(services.activity.keptAsIs == 2)
        await services.prepareForTermination()
    }

    @Test func observersHearEveryChangeAndTheEndOfARun() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = makeServices(directory: directory)
        services.register(InstantTool())
        var snapshots = 0
        var summaries: [QueueRunSummary] = []
        services.observeJobs { _ in snapshots += 1 }
        services.observeRunFinished { summaries.append($0) }
        await services.start()
        await services.queue.enqueue([job(tool: "instant", name: "a")])
        while summaries.isEmpty { await Task.yield() }
        #expect(snapshots > 0)
        #expect(summaries.first?.keptAsIs == 1)
        await services.prepareForTermination()
    }

    @Test func jobsExcludedFromTheRunSummaryDoNotMakeOne() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = makeServices(directory: directory)
        services.register(InstantTool())
        let quick = job(tool: "instant", name: "quick")
        services.jobsExcludedFromRunSummary = { [quick.id] }
        var summaries = 0
        services.observeRunFinished { _ in summaries += 1 }
        await services.start()
        await services.queue.enqueue([quick])
        while services.jobs.isEmpty || services.jobs.contains(where: { $0.state.isPending }) { await Task.yield() }
        #expect(summaries == 0)
        await services.prepareForTermination()
    }

    @Test func autoStartOffPausesTheQueueFromTheStart() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: SettingsStore.Keys.autoStartQueue)
        let services = makeServices(directory: directory, defaults: defaults)
        #expect(services.isQueuePaused)
        #expect(await services.queue.isPaused())
    }

    @Test func theSpeedIsReadFromAndWrittenToTheSharedSettings() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = isolatedDefaults()
        defaults.set("fastest", forKey: SettingsStore.Keys.speed)
        let services = makeServices(directory: directory, defaults: defaults)
        #expect(services.speed == .fastest)
        services.speed = .quiet
        #expect(defaults.string(forKey: SettingsStore.Keys.speed) == "quiet")
    }

    @Test func aSavedJobOfAnUnknownToolSurvivesAStartWithoutItsTool() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let future = Job(
            toolID: "future-tool", source: URL(filePath: "/tmp/f.mov"), sourceBookmark: Data(),
            settings: Data("opaque".utf8))
        try JobStore(directory: directory).save([future])
        let services = makeServices(directory: directory)
        await services.start()
        await services.prepareForTermination()
        let saved = JobStore(directory: directory).load()
        #expect(saved.map(\.id) == [future.id])
        #expect(saved.first?.settings == Data("opaque".utf8))
        #expect(saved.first?.toolID == "future-tool")
    }

    @Test func startSweepsStagedCopiesNoJobReads() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leftover = StagedInputs(
            directory: directory.appending(path: AppServices.stagingFolderName, directoryHint: .isDirectory))
        let copy = try leftover.stage(name: "left.mov", data: Data([1, 2, 3]))
        let services = makeServices(directory: directory)
        await services.start()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        await services.prepareForTermination()
    }

    @Test func waitUntilStartedReturnsOnceStartHasFinished() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = makeServices(directory: directory)
        async let waited: Void = services.waitUntilStarted()
        await services.start()
        await waited
        // A second wait after the start returns at once.
        await services.waitUntilStarted()
        await services.prepareForTermination()
    }

    @Test func theSupportDirectoryIsUnderApplicationSupportUnlessATestLaunchOverridesIt() {
        let normal = AppServices.supportDirectory(bundleIdentifier: "id.example.app")
        #expect(normal.lastPathComponent == "id.example.app")
        #expect(normal.deletingLastPathComponent().standardizedFileURL == URL.applicationSupportDirectory.standardizedFileURL)
        let override = URL(filePath: "/tmp/ui-test", directoryHint: .isDirectory)
        #expect(AppServices.supportDirectory(bundleIdentifier: "id.example.app", override: override) == override)
    }

    @Test func theLibraryServiceHoldsBothLibrariesAndTheirThumbnails() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = makeServices(directory: directory)
        #expect(services.library.local.items.isEmpty)
        #expect(services.library.thumbnailSource.photos is FakePhotoStore)
        #expect(ThumbnailSource.size(for: CGSize(width: 200, height: 100), maxPixel: 50) == CGSize(width: 50, height: 25))
        #expect(ThumbnailSource.size(for: .zero, maxPixel: 50) == CGSize(width: 50, height: 50))
    }
}

@Suite struct SettingsStoreTests {
    @Test func theKeysAreTheOnesAlreadyOnEveryMac() {
        #expect(SettingsStore.Keys.autoStartQueue == "queue.autoStart")
        #expect(SettingsStore.Keys.speed == "performance.speed")
    }

    @Test func defaultsAreOnAndBalancedAndAnUnknownSpeedFallsBack() {
        let store = SettingsStore(isolatedDefaults())
        #expect(store.autoStartQueue)
        #expect(store.speed == .balanced)
        store.defaults.set("warp", forKey: SettingsStore.Keys.speed)
        #expect(store.speed == .balanced)
    }
}
