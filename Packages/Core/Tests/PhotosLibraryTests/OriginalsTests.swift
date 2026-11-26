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
