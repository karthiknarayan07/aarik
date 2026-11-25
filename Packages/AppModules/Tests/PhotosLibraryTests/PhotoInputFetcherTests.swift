import Foundation
import Synchronization
import Testing

@testable import PhotosLibrary

private final class Recorder: Sendable {
    private let events = Mutex<[FetchProgress]>([])
    func add(_ event: FetchProgress) { events.withLock { $0.append(event) } }
    var all: [FetchProgress] { events.withLock { $0 } }
}

private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@Suite struct PhotoInputFetcherTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "PhotoInputFetcherTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func isDownloading(_ progress: FetchProgress) -> Bool {
        if case .downloading = progress { true } else { false }
    }

    @Test func uneditedVideoWritesTheOriginal() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset()
        let store = FakePhotoStore(assets: [asset])
        store.inputBytes = 2_000
        let input = try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir)
        #expect(!input.isEditedVersion)
        #expect(input.bytes == 2_000)
        #expect(input.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(input.url.lastPathComponent == "IMG_4211.MOV")
        #expect(FileManager.default.fileExists(atPath: input.url.path))
        #expect(store.inputRequests.map(\.kind) == [.original])
    }

    @Test func editedVideoGoesThroughTheExport() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset(hasAdjustments: true)
        let store = FakePhotoStore(assets: [asset])
        let input = try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir)
        #expect(input.isEditedVersion)
        #expect(input.url.lastPathComponent == "IMG_4211-edited.mov")
        #expect(store.inputRequests.map(\.kind) == [.currentVersion])
    }

    @Test func downloadProgressIsItsOwnPhaseBeforeExporting() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset(hasAdjustments: true)
        let store = FakePhotoStore(assets: [asset])
        let recorder = Recorder()
        _ = try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir) { recorder.add($0) }
        let events = recorder.all
        #expect(events.first == .downloading(0.25))
        #expect(events.contains(.downloading(1)))
        #expect(events.last == .exporting(1))
        let firstExport = try #require(events.firstIndex { !isDownloading($0) })
        #expect(events[..<firstExport].allSatisfy(isDownloading))
        // Each phase runs 0 to 1 by itself.
        #expect(events.map(\.fraction).allSatisfy { $0 > 0 && $0 <= 1 })
    }

    @Test func uneditedProgressIsDownloadingOnly() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset()
        let store = FakePhotoStore(assets: [asset])
        let recorder = Recorder()
        _ = try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir) { recorder.add($0) }
        #expect(recorder.all == [.downloading(0.25), .downloading(0.5), .downloading(0.75), .downloading(1)])
    }

    @Test func deletedAssetIsNotInLibrary() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakePhotoStore(assets: [])
        await #expect(throws: PhotoFetchError.notInLibrary) {
            try await PhotoInputFetcher(store: store).fetch(id: "gone/L0/001", into: dir)
        }
        #expect(names(in: dir).isEmpty)
    }

    @Test(arguments: [false, true])
    func downloadFailureMentionsICloudAndLeavesNothing(edited: Bool) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset(hasAdjustments: edited)
        let store = FakePhotoStore(assets: [asset])
        store.inputError = .downloadFailed("network access required (3164)")
        let error = await #expect(throws: PhotoFetchError.self) {
            try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir)
        }
        #expect(error == .downloadFailed(underlying: "network access required (3164)"))
        let message = try #require(error?.errorDescription)
        #expect(message.contains("iCloud") && message.contains("online"))
        #expect(names(in: dir).isEmpty)
    }

    @Test func otherFailureIsNotCalledADownloadProblem() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset()
        let store = FakePhotoStore(assets: [asset])
        store.inputError = .unavailable("no video resource")
        let error = await #expect(throws: PhotoFetchError.self) {
            try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir)
        }
        #expect(error == .failed("no video resource"))
        #expect(names(in: dir).isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellingMidFetchRemovesThePartialFile(edited: Bool) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset(hasAdjustments: edited)
        let store = FakePhotoStore(assets: [asset])
        let reached = Latch()
        let release = Latch()
        store.beforeInputStep = { step in
            guard step == 2 else { return }
            await reached.open()
            await release.wait()
        }
        let fetch = Task { try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir) }
        await reached.wait()
        #expect(!names(in: dir).isEmpty, "a partial file exists while the fetch is held")
        fetch.cancel()
        await release.open()
        let result = await fetch.result
        #expect(throws: PhotoFetchError.cancelled) { try result.get() }
        #expect(names(in: dir).isEmpty)
    }

    @Test func aStaleFileIsReplaced() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset()
        try Data(repeating: 1, count: 9_999).write(to: dir.appending(path: "IMG_4211.MOV"))
        let store = FakePhotoStore(assets: [asset])
        store.inputBytes = 400
        let input = try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: dir)
        #expect(input.bytes == 400)
    }

    @Test func nameIsSafeWhenPhotosGivesNoneOrAPath() {
        func name(_ original: String, edited: Bool) -> String {
            let asset = PhotoAsset(
                id: "a", pixelSize: .zero, duration: 1, hasAdjustments: edited, originalFileName: original)
            return PhotoInputFetcher.fileName(for: asset, isEdited: edited)
        }
        #expect(name("", edited: false) == "video.mov")
        #expect(name("", edited: true) == "video-edited.mov")
        #expect(name("../../evil.MOV", edited: false) == "evil.MOV")
    }
}
