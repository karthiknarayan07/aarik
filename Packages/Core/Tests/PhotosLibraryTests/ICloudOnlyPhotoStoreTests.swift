import Foundation
import Synchronization
import Testing

@testable import PhotosLibrary

@Suite struct ICloudOnlyPhotoStoreTests {
    private func store(_ ids: String...) -> ICloudOnlyPhotoStore {
        ICloudOnlyPhotoStore(assets: ids.map { Samples.asset(id: $0) })
    }

    private func target() -> URL {
        URL.temporaryDirectory.appending(path: "icloud-\(UUID().uuidString).mov")
    }

    @Test func everyVideoStartsOnlyInICloud() async throws {
        let store = store("A", "B")
        let assets = try await store.videos()
        #expect(assets.map(\.isLocallyAvailable) == [false, false])
        #expect(try await store.asset(id: "A").isLocallyAvailable == false)
    }

    @Test func aDownloadReportsProgressAndThenTheVideoIsOnTheDevice() async throws {
        let store = store("A", "B")
        let url = target()
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Mutex<[FetchProgress]>([])

        try await store.writeOriginal(id: "A", to: url) { value in seen.withLock { $0.append(value) } }

        #expect(seen.withLock { $0 } == [0.25, 0.5, 0.75, 1].map(FetchProgress.downloading))
        #expect(store.downloadedIDs == ["A"])
        #expect(try await store.asset(id: "A").isLocallyAvailable == true)
        // Only the downloaded one changed.
        #expect(try await store.asset(id: "B").isLocallyAvailable == false)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFailedDownloadLeavesAPartialFileAndTheVideoInICloud() async throws {
        let store = store("A", "B")
        store.failDownload(of: "A")
        let url = target()
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Mutex<[FetchProgress]>([])

        await #expect(throws: PhotoStoreError.downloadFailed("offline")) {
            try await store.writeOriginal(id: "A", to: url) { value in seen.withLock { $0.append(value) } }
        }

        #expect(seen.withLock { $0 } == [.downloading(0.5)])
        #expect(store.downloadedIDs.isEmpty)
        #expect(try await store.asset(id: "A").isLocallyAvailable == false)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // The other video is unaffected.
        let other = target()
        defer { try? FileManager.default.removeItem(at: other) }
        try await store.writeOriginal(id: "B", to: other) { _ in }
        #expect(store.downloadedIDs == ["B"])
        #expect(store.downloadAttempts == ["A", "B"])
    }

    @Test func aRepairedDownloadSucceedsOnRetry() async throws {
        let store = store("A")
        store.failDownload(of: "A", with: .downloadFailed("timed out"))
        let url = target()
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PhotoStoreError.downloadFailed("timed out")) {
            try await store.writeOriginal(id: "A", to: url) { _ in }
        }
        store.repairDownload(of: "A")
        try await store.exportCurrentVersion(id: "A", to: url) { _ in }
        #expect(store.downloadedIDs == ["A"])
    }
}
