import AppCore
import Foundation
import Testing

@testable import PhotosLibrary

@Suite struct SavedCopyTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "SavedCopyTests-\(UUID().uuidString)/pending.json")
    }

    private func copy(job: UUID, original: String = "A/L0/001", new: String = "new-1") -> SavedCopy {
        let outcome = JobOutcome(
            output: PhotoAssetURL.url(for: new), bytesBefore: 100, bytesAfter: 40, report: MetadataReport(),
            replacedOriginal: false, notes: ["Saved to Photos as a new video"])
        return SavedCopy(
            jobID: job, originalID: original, newID: new, outcome: outcome,
            originalModified: Date(timeIntervalSince1970: 1_750_000_000), originalHadAdjustments: false)
    }

    @Test func aSavedCopySurvivesARelaunchWithItsBackup() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = UUID()
        let first = PendingDeletions(fileURL: url)
        first.markSaved(copy(job: job))
        first.setBackup(URL(filePath: "/Volumes/Backup/IMG_1.MOV"), forJob: job)

        let second = PendingDeletions(fileURL: url)
        #expect(second.savedCopy(for: job)?.newID == "new-1")
        #expect(second.savedCopy(for: job)?.backup == URL(filePath: "/Volumes/Backup/IMG_1.MOV"))
        #expect(second.savedCopy(for: UUID()) == nil)
        second.setBackup(nil, forJob: job)
        #expect(PendingDeletions(fileURL: url).savedCopy(for: job)?.backup == nil)
    }

    @Test func savedCopiesAreKeptOnlyForTheJobsStillInTheQueue() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let kept = UUID()
        let finished = UUID()
        let pending = PendingDeletions(fileURL: url)
        pending.markSaved(copy(job: kept))
        pending.markSaved(copy(job: finished, original: "B/L0/001", new: "new-2"))
        pending.add(assetID: "B/L0/001", jobID: finished, replacedBy: "new-2")

        pending.keepSavedCopies(forJobs: [kept])

        #expect(pending.savedCopy(for: kept) != nil)
        #expect(pending.savedCopy(for: finished) == nil)
        // The originals waiting for deletion are not touched.
        #expect(pending.all.map(\.assetID) == ["B/L0/001"])
        #expect(PendingDeletions(fileURL: url).savedCopy(for: finished) == nil)
    }

    @Test func aFileWrittenBeforeSavedCopiesExistedStillReadsAsPendingOriginals() throws {
        let url = file()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = UUID()
        try JSONEncoder().encode([PendingDeletion(assetID: "A", jobID: job, replacedBy: "n1")]).write(to: url)

        let pending = PendingDeletions(fileURL: url)
        #expect(pending.all == [PendingDeletion(assetID: "A", jobID: job, replacedBy: "n1")])
        #expect(pending.savedCopy(for: job) == nil)
    }
}

@Suite struct OriginalsDeleterTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "OriginalsDeleterTests-\(UUID().uuidString)/pending.json")
    }

    private func library(_ ids: [String]) -> (FakePhotoStore, PendingDeletions, URL) {
        let url = file()
        let store = FakePhotoStore(assets: ids.map { Samples.asset(id: $0) })
        let pending = PendingDeletions(fileURL: url)
        for id in ids { pending.add(assetID: id, jobID: UUID(), replacedBy: "new-\(id)") }
        return (store, pending, url)
    }

    @Test func oneDeleteCallMovesEveryPendingOriginalAndEmptiesTheList() async throws {
        let (store, pending, url) = library(["A", "B", "C"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(result.moved.map(\.assetID) == ["A", "B", "C"])
        #expect(result.kept.isEmpty)
        #expect(store.deletedIDs == ["A", "B", "C"])
        #expect(store.operations.filter { if case .delete = $0 { true } else { false } }.count == 1)
        #expect(pending.all.isEmpty)
        #expect(PendingDeletions(fileURL: url).all.isEmpty)
    }

    @Test func aDeclinedConfirmationKeepsTheListAndDeletesNothing() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.deleteError = CancellationError()

        await #expect(throws: CancellationError.self) {
            _ = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        }

        #expect(store.deletedIDs.isEmpty)
        #expect(pending.all.map(\.assetID) == ["A", "B"])
        // Surviving a relaunch: the originals can be moved later.
        #expect(PendingDeletions(fileURL: url).all.map(\.assetID) == ["A", "B"])
        // Asking again after the decline works.
        store.deleteError = nil
        let again = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        #expect(again.moved.count == 2)
        #expect(pending.all.isEmpty)
    }

    @Test func anOriginalTheUserAlreadyDeletedIsDoneAndNotSentAgain() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.assets = store.assets.filter { $0.id != "A" }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(result.moved.map(\.assetID) == ["A", "B"])
        #expect(store.deletedIDs == ["B"])
        #expect(pending.all.isEmpty)
    }

    @Test func aRefusalFromPhotosKeepsTheListAndIsReported() async throws {
        let (store, pending, url) = library(["A"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.deleteError = PhotoStoreError.notAuthorized

        await #expect(throws: PhotoStoreError.notAuthorized) {
            _ = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        }
        #expect(pending.all.map(\.assetID) == ["A"])
    }

    @Test func nothingPendingMakesNoDeleteCall() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FakePhotoStore(assets: [])

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: PendingDeletions(fileURL: url))

        #expect(result == OriginalsDeletion())
        #expect(store.operations.isEmpty)
    }
}
