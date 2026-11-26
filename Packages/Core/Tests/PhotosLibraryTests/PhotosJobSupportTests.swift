import Foundation
import Testing

@testable import PhotosLibrary

@Suite struct PhotoAssetURLTests {
    @Test func theAddressRoundTripsALocalIdentifierWithSlashes() throws {
        let id = "6F1C7A0E-1111-2222-3333-444455556666/L0/001"
        let url = PhotoAssetURL.url(for: id)
        #expect(url.scheme == PhotoAssetURL.scheme)
        #expect(!url.isFileURL)
        #expect(PhotoAssetURL.identifier(from: url) == id)
    }

    @Test func aFileOrAnotherSchemeHasNoIdentifier() {
        #expect(PhotoAssetURL.identifier(from: URL(fileURLWithPath: "/tmp/a.mov")) == nil)
        #expect(PhotoAssetURL.identifier(from: URL(string: "https://example.com/a")!) == nil)
    }

    @Test func differentIdentifiersGiveDifferentAddresses() {
        #expect(PhotoAssetURL.url(for: "A/L0/001") != PhotoAssetURL.url(for: "B/L0/001"))
    }
}

@Suite struct PendingDeletionsTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "PendingDeletionsTests-\(UUID().uuidString)/pending.json")
    }

    @Test func recordedEntriesSurviveARelaunch() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = UUID()
        let first = PendingDeletions(fileURL: url)
        first.add(assetID: "A/L0/001", jobID: job, replacedBy: "new-1")

        let second = PendingDeletions(fileURL: url)
        #expect(second.all == [PendingDeletion(assetID: "A/L0/001", jobID: job, replacedBy: "new-1")])
    }

    @Test func addingTheSameOriginalTwiceKeepsOneEntry() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pending = PendingDeletions(fileURL: url)
        pending.add(assetID: "A", jobID: UUID(), replacedBy: "n1")
        pending.add(assetID: "A", jobID: UUID(), replacedBy: "n2")
        #expect(pending.all.count == 1)
        #expect(pending.all.first?.replacedBy == "n2")
    }

    @Test func removeTakesOutOnlyTheNamedOriginals() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pending = PendingDeletions(fileURL: url)
        for id in ["A", "B", "C"] { pending.add(assetID: id, jobID: UUID(), replacedBy: "n-\(id)") }
        pending.remove(assetIDs: ["A", "C"])
        #expect(pending.all.map(\.assetID) == ["B"])
        #expect(PendingDeletions(fileURL: url).all.map(\.assetID) == ["B"])
    }

    @Test func anUnreadableFileStartsEmptyAndIsNotOverwrittenUntilSomethingIsAdded() throws {
        let url = file()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not json".utf8).write(to: url)
        let pending = PendingDeletions(fileURL: url)
        #expect(pending.all.isEmpty)
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }
}

@Suite struct FetchOriginalTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "FetchOriginalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anEditedVideosOriginalIsFetchedAsTheOriginalResource() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset(hasAdjustments: true)
        let store = FakePhotoStore(assets: [asset])
        let fetcher = PhotoInputFetcher(store: store)

        let edited = try await fetcher.fetch(id: asset.id, into: dir)
        let original = try await fetcher.fetchOriginal(id: asset.id, into: dir)

        #expect(store.inputRequests.map(\.kind) == [.currentVersion, .original])
        #expect(edited.url.lastPathComponent == "IMG_4211-edited.mov")
        #expect(original.url.lastPathComponent == "IMG_4211.MOV")
        #expect(!original.isEditedVersion)
        #expect(FileManager.default.fileExists(atPath: edited.url.path))
        #expect(FileManager.default.fileExists(atPath: original.url.path))
    }

    @Test func aFailedOriginalFetchLeavesNoPartialFileAndMapsTheError() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset(hasAdjustments: true)
        let store = FakePhotoStore(assets: [asset])
        store.inputError = .downloadFailed("offline")

        await #expect(throws: PhotoFetchError.downloadFailed(underlying: "offline")) {
            _ = try await PhotoInputFetcher(store: store).fetchOriginal(id: asset.id, into: dir)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
    }

    @Test func theFakeWritesAGivenFileInsteadOfFiller() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = Samples.asset()
        let source = dir.appending(path: "clip.bin")
        try Data("real bytes".utf8).write(to: source)
        let store = FakePhotoStore(assets: [asset])
        store.originalFiles[asset.id] = source
        let work = dir.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let input = try await PhotoInputFetcher(store: store).fetch(id: asset.id, into: work)

        #expect(try Data(contentsOf: input.url) == Data("real bytes".utf8))
    }
}
