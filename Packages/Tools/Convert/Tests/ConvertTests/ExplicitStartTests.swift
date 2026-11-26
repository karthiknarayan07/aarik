import AppCore
import AppServices
import Foundation
import PhotosLibrary
import Testing

@testable import Convert
@testable import ConvertUI

/// On iOS a run starts only when the person starts it: Add to Queue only queues, Convert Now queues and starts, and
/// the Queue's Start button says what the waiting videos would save.
@MainActor
@Suite struct ExplicitStartTests {
    private struct Rig {
        let model: ConvertModel
        let directory: URL
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func rig(autoStartDefault: Bool = false) async throws -> Rig {
        let directory = URL.temporaryDirectory.appending(
            path: "explicit-start-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let asset = PhotoAsset(
            id: "A/L0/001", creationDate: modified, location: nil, pixelSize: CGSize(width: 3840, height: 2160),
            duration: 30, originalFileName: "Beach.MOV", originalByteSize: 900_000_000, modificationDate: modified)
        let suite = UserDefaults(suiteName: "ExplicitStartTests-\(UUID().uuidString)")!
        let services = AppServices(
            directory: directory, defaults: suite, photoStore: FakePhotoStore(assets: [asset]),
            autoStartDefault: autoStartDefault)
        let model = ConvertModel(services: services)
        await model.start()
        await model.photos.start()
        await model.photos.waitUntilIdle()
        model.selection = .photosVideos
        model.photosBrowser.selection = Set(model.photos.items.map(\.id))
        try #require(model.canAddSelectionToQueue)
        return Rig(model: model, directory: directory)
    }

    /// Lets the add's queue commands reach the queue and the mirror catch up.
    private func settle(_ model: ConvertModel) async {
        await model.services.waitForQueueCommands()
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func addToQueueOnlyQueuesWithTheIOSDefault() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.model.requestAddSelectionToQueue(startsQueue: false)
        await settle(rig.model)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.model.queuedJobs.count == 1)
        #expect(rig.model.isQueuePaused)
        #expect(rig.model.jobs.allSatisfy { $0.state == .queued })
        #expect(rig.model.waitsForStart)
    }

    @Test func addingWithoutSayingFollowsTheIOSDefaultAndDoesNotStart() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.model.requestAddSelectionToQueue()
        await settle(rig.model)
        #expect(rig.model.isQueuePaused)
        #expect(rig.model.jobs.allSatisfy { $0.state == .queued })
    }

    @Test func convertNowQueuesAndStartsTheQueue() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.model.convertSelectionNow()
        #expect(!rig.model.isQueuePaused)
        await settle(rig.model)
        #expect(rig.model.jobs.count == 1)
        #expect(!rig.model.waitsForStart)
        await rig.model.prepareForTermination()
    }

    @Test func theMacDefaultStillStartsOnAdd() async throws {
        let rig = try await rig(autoStartDefault: true)
        defer { rig.cleanUp() }
        rig.model.requestAddSelectionToQueue()
        #expect(!rig.model.isQueuePaused)
        await settle(rig.model)
        await rig.model.prepareForTermination()
    }

    @Test func theQueuedSavingIsRememberedWithTheJobAndAddsUp() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        let settings = ConvertJobSettings(saveTo: .documents)
        let jobs = PhotosJobFactory.makeJobs(
            for: [
                (assetID: "x", name: "x.MOV", preset: .balanced), (assetID: "y", name: "y.MOV", preset: .balanced),
                (assetID: "z", name: "z.MOV", preset: .balanced),
            ], settings: settings, destination: .newAsset, savings: ["x": 400, "y": 250])
        await rig.model.services.queue.enqueue(jobs)
        await settle(rig.model)
        // A video without an estimate adds nothing.
        #expect(rig.model.queuedSavingEstimate == 650)
    }

    @Test func startQueueRunsWhatWaits() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        rig.model.requestAddSelectionToQueue(startsQueue: false)
        await settle(rig.model)
        #expect(rig.model.waitsForStart)
        rig.model.startQueue()
        #expect(!rig.model.isQueuePaused)
        await settle(rig.model)
        await rig.model.prepareForTermination()
    }

    @Test func aHandedOffVideoIsQueuedButDoesNotStart() async throws {
        let rig = try await rig()
        defer { rig.cleanUp() }
        let file = rig.directory.appending(path: "shared.mov")
        try Data(count: 16).write(to: file)
        rig.model.queueHandedOff([file])
        await settle(rig.model)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.model.queuedJobs.count == 1)
        #expect(rig.model.isQueuePaused)
        #expect(rig.model.jobs.allSatisfy { $0.state == .queued })
    }

    @Test func settingsWithoutAnEstimateStillDecode() throws {
        let old = #"{"preset":"balanced","saveTo":{"nextToOriginal":{}}}"#
        let settings = try JSONDecoder().decode(ConvertJobSettings.self, from: Data(old.utf8))
        #expect(settings.estimatedSavedBytes == nil)
    }
}
