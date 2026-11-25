import AppCore
import CoreGraphics
import Foundation
import PhotosLibrary
import Synchronization
import Testing

@testable import DownscaleVideo

/// A store that forwards to a fake and calls `onAsset` at each `asset(id:)`, so a test can cancel the run at a
/// chosen moment inside the Replace steps.
private struct WatchingStore: PhotoStore {
    let base: FakePhotoStore
    let onAsset: @Sendable () -> Void

    func authorization() async -> PhotoAuthorization { await base.authorization() }
    func requestAuthorization() async -> PhotoAuthorization { await base.requestAuthorization() }
    func videos() async throws -> [PhotoAsset] { try await base.videos() }
    func changes() -> AsyncStream<Void> { base.changes() }
    func albums(containing id: String) async throws -> [String] { try await base.albums(containing: id) }
    func thumbnail(for id: String, size: CGSize) async -> CGImage? { await base.thumbnail(for: id, size: size) }
    func asset(id: String) async throws -> PhotoAsset {
        onAsset()
        return try await base.asset(id: id)
    }
    func saveVideo(_ request: PhotoSaveRequest) async throws -> String { try await base.saveVideo(request) }
    func deleteAssets(ids: [String]) async throws { try await base.deleteAssets(ids: ids) }
    func writeOriginal(id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void) async throws {
        try await base.writeOriginal(id: id, to: url, progress: progress)
    }
    func exportCurrentVersion(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        try await base.exportCurrentVersion(id: id, to: url, progress: progress)
    }
}

/// A job that is put back in the queue after its copy was saved (a crash or a quit) must not save a second copy,
/// and a cancel must not leave an unrecorded backup behind.
@Suite struct PhotosRunnerResumeTests {
    private func completed(_ state: JobState) -> JobOutcome? {
        if case .completed(let outcome) = state { return outcome }
        Issue.record("expected completed, got \(state)")
        return nil
    }

    /// Runs the job with `runner` and cancels it when `trigger` says so; returns the error, if any.
    private func runCancelling(
        _ runner: PhotosDownscaleRunner, _ job: Job,
        when trigger: @escaping @Sendable (_ phase: String, _ progress: Double?) -> Bool
    ) async -> (any Error)? {
        let cancel = CancelSwitch()
        let current = Mutex("")
        let task = Task<JobState, any Error> {
            try await runner.run(
                job,
                progress: { value in
                    if trigger(current.withLock { $0 }, value) { cancel.cancel() }
                },
                phase: { phase in
                    guard let phase else { return }
                    current.withLock { $0 = phase }
                    if trigger(phase, nil) { cancel.cancel() }
                })
        }
        cancel.set(task)
        do {
            _ = try await task.value
            return nil
        } catch {
            return error
        }
    }

    // MARK: - New asset

    @Test(.timeLimit(.minutes(2))) func aRequeuedNewAssetJobDoesNotSaveASecondCopy() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job()
        let first = try #require(completed(try await rig.runner().run(job) { _ in }))
        #expect(rig.pending.savedCopy(for: job.id)?.newID == "new-1")
        let requests = rig.store.inputRequests.count

        // The app was quit or crashed before the queue saved the job as finished: it runs again.
        let again = try #require(completed(try await rig.runner().run(job) { _ in }))

        #expect(rig.store.saves.count == 1)
        #expect(again == first)
        #expect(rig.store.inputRequests.count == requests)  // nothing was downloaded again
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func ifTheSavedCopyIsGoneTheVideoIsConvertedAgain() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job()
        _ = try await rig.runner().run(job) { _ in }
        rig.store.assets.removeAll { $0.id == "new-1" }  // the user removed the copy meanwhile

        let again = try #require(completed(try await rig.runner().run(job) { _ in }))

        #expect(rig.store.saves.count == 2)
        #expect(again.output == PhotoAssetURL.url(for: "new-2"))
        #expect(rig.pending.savedCopy(for: job.id)?.newID == "new-2")
    }

    // MARK: - Replace

    @Test(.timeLimit(.minutes(2))) func aQuitRightAfterTheSaveLetsTheReplaceFinishWithoutASecondCopy() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job(.replace)

        // Stopped once the new video is saved, before the original is recorded.
        let error = await runCancelling(rig.runner(backup: true), job) { phase, progress in
            phase == "Saving to Photos…" && progress == 1
        }
        #expect(error is CancellationError)
        #expect(rig.store.saves.count == 1)
        #expect(rig.pending.all.isEmpty)

        let outcome = try #require(completed(try await rig.runner(backup: true).run(job) { _ in }))

        #expect(rig.store.saves.count == 1)
        #expect(rig.pending.all == [PendingDeletion(assetID: rig.asset.id, jobID: job.id, replacedBy: "new-1")])
        #expect(outcome.output == PhotoAssetURL.url(for: "new-1"))
        #expect(outcome.notes == ["Saved to Photos as a new video", "Original will move to Recently Deleted"])
        #expect(rig.backupContents == ["IMG_0001.MOV"])
        #expect(rig.workContents.isEmpty)
        #expect(rig.store.deletedIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func aQuitDuringTheBackupWritesOneBackupAndOneCopy() async throws {
        let rig = try await PhotosRig(hasAdjustments: true)
        let job = try rig.job(.replace)

        let error = await runCancelling(rig.runner(backup: true), job) { phase, _ in
            phase == "Downloading the original for the backup…"
        }
        #expect(error is CancellationError)
        #expect(rig.store.saves.count == 1)
        #expect(rig.backupContents.isEmpty)

        let outcome = try #require(completed(try await rig.runner(backup: true).run(job) { _ in }))

        #expect(rig.store.saves.count == 1)
        #expect(rig.backupContents == ["IMG_0001.MOV"])
        #expect(rig.pending.all.count == 1)
        #expect(outcome.warnings.isEmpty)
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func aRequeuedJobWhoseOriginalIsAlreadyRecordedFinishesAtOnce() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job(.replace)
        let first = try #require(completed(try await rig.runner(backup: true).run(job) { _ in }))
        let requests = rig.store.inputRequests.count

        let again = try #require(completed(try await rig.runner(backup: true).run(job) { _ in }))

        #expect(again == first)
        #expect(rig.store.saves.count == 1)
        #expect(rig.pending.all.count == 1)
        #expect(rig.store.inputRequests.count == requests)
        #expect(rig.backupContents == ["IMG_0001.MOV"])  // not written twice
    }

    @Test(.timeLimit(.minutes(2))) func aBackupAlreadyWrittenIsNotWrittenAgain() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job(.replace)
        _ = try await rig.runner(backup: true).run(job) { _ in }
        // As after a crash between writing the backup and recording the original.
        rig.pending.remove(assetIDs: [rig.asset.id])
        #expect(rig.pending.savedCopy(for: job.id)?.backup != nil)

        let outcome = try #require(completed(try await rig.runner(backup: true).run(job) { _ in }))

        #expect(rig.backupContents == ["IMG_0001.MOV"])
        #expect(rig.pending.all.count == 1)
        #expect(outcome.warnings.isEmpty)
    }

    // MARK: - An orphan backup

    @Test(.timeLimit(.minutes(2))) func aCancelAfterTheBackupIsWrittenRemovesTheBackup() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job(.replace)
        let cancel = CancelSwitch()
        let folder = rig.backup
        // Cancel at the first look at the original once the backup file is there: the last step before recording.
        let store = WatchingStore(base: rig.store) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if !files.isEmpty { cancel.cancel() }
        }
        let runner = PhotosDownscaleRunner(
            store: store, workFolder: rig.workFolder, pendingDeletions: rig.pending, core: DownscaleRunner(),
            originalsBackup: { OriginalsBackup(folder: folder) })
        let task = Task<JobState, any Error> { try await runner.run(job) { _ in } }
        cancel.set(task)

        let error: (any Error)?
        do {
            _ = try await task.value
            error = nil
        } catch let thrown {
            error = thrown
        }

        #expect(error is CancellationError)
        // The backup had no record saying what it was for, so it was removed again.
        #expect(rig.backupContents.isEmpty)
        #expect(rig.pending.all.isEmpty)
        #expect(rig.pending.savedCopy(for: job.id)?.backup == nil)
        #expect(rig.store.saves.count == 1)
        #expect(rig.workContents.isEmpty)
    }

    // MARK: - After the delete

    @Test(.timeLimit(.minutes(2))) func theRecordedOriginalCarriesTheBaselineItWasVerifiedAgainst() async throws {
        let rig = try await PhotosRig()
        let job = try rig.job(.replace)

        _ = try await rig.runner().run(job) { _ in }

        let entry = try #require(rig.pending.all.first)
        #expect(entry.hasBaseline)
        #expect(entry.originalModified == rig.asset.modificationDate)
        #expect(entry.originalHadAdjustments == rig.asset.hasAdjustments)
        #expect(entry.blocked == nil)
    }

    @Test func aKeptOriginalIsSaidOnTheJobAndLaterMovingClearsIt() {
        var outcome = JobOutcome(
            output: PhotoAssetURL.url(for: "new-1"), bytesBefore: 100, bytesAfter: 40, report: MetadataReport(),
            replacedOriginal: false,
            notes: ["Saved to Photos as a new video", "Original will move to Recently Deleted"])

        PhotosDownscaleRunner.markOriginalKept(&outcome, because: PendingBlock.originalChanged.message)
        PhotosDownscaleRunner.markOriginalKept(&outcome, because: PendingBlock.originalChanged.message)

        #expect(outcome.warnings == ["Kept the original because it changed after shrinking"])
        #expect(!outcome.notes.contains("Original will move to Recently Deleted"))
        #expect(!outcome.replacedOriginal)

        PhotosDownscaleRunner.markOriginalMoved(&outcome)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.replacedOriginal)
    }

    @Test func anOriginalAlreadyGoneIsSaidAsSuch() {
        var outcome = JobOutcome(
            output: PhotoAssetURL.url(for: "new-1"), bytesBefore: 100, bytesAfter: 40, report: MetadataReport(),
            replacedOriginal: false, notes: ["Original will move to Recently Deleted"])

        PhotosDownscaleRunner.markOriginalGone(&outcome)

        #expect(outcome.notes == ["Original no longer in Photos"])
        #expect(!outcome.replacedOriginal)
    }

    @Test func markingAnOriginalMovedUpdatesTheOutcome() {
        var outcome = JobOutcome(
            output: PhotoAssetURL.url(for: "new-1"), bytesBefore: 100, bytesAfter: 40, report: MetadataReport(),
            replacedOriginal: false,
            notes: ["Saved to Photos as a new video", "Original will move to Recently Deleted"])

        PhotosDownscaleRunner.markOriginalMoved(&outcome)
        PhotosDownscaleRunner.markOriginalMoved(&outcome)

        #expect(outcome.replacedOriginal)
        #expect(outcome.notes == ["Saved to Photos as a new video", "Original moved to Recently Deleted"])
    }
}
