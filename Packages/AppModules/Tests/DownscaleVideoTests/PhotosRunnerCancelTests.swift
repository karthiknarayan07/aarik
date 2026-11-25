import AppCore
import Foundation
import PhotosLibrary
import Synchronization
import Testing

@testable import DownscaleVideo

/// Holds the task a test cancels from inside a callback; a cancel asked for before the task is set happens as soon
/// as it is.
final class CancelSwitch: Sendable {
    private struct State {
        var task: Task<JobState, any Error>?
        var wanted = false
    }

    private let state = Mutex(State())

    func set(_ task: Task<JobState, any Error>) {
        let cancelNow = state.withLock { state in
            state.task = task
            return state.wanted
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.wanted = true
            return state.task
        }
        task?.cancel()
    }
}

/// Cancelling a run in each phase, and changes made in Photos while a run is under way.
@Suite struct PhotosRunnerCancelTests {
    /// Runs the job and cancels it when `trigger` says so. `trigger` sees each phase label as it begins (with
    /// `progress` nil) and each progress value (with the label of the phase it belongs to).
    private func runCancelling(
        _ rig: PhotosRig, _ job: Job, backup: Bool = false,
        when trigger: @escaping @Sendable (_ phase: String, _ progress: Double?) -> Bool
    ) async throws -> (any Error)? {
        let cancel = CancelSwitch()
        let runner = rig.runner(backup: backup)
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

    private func expectLeftNothing(_ rig: PhotosRig, folder: URL? = nil) {
        #expect(rig.workContents.isEmpty)
        #expect(rig.pending.all.isEmpty)
        #expect(rig.store.deletedIDs.isEmpty)
        if let folder {
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(2))) func cancellingTheRenderOfAnEditLeavesNothing() async throws {
        let rig = try await PhotosRig(hasAdjustments: true)

        let error = try await runCancelling(rig, try rig.job(.replace)) { phase, _ in
            phase == "Rendering the edited version…"
        }

        #expect(error is CancellationError)
        #expect(rig.store.assets == [rig.asset])
        expectLeftNothing(rig)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingWhileConvertingLeavesNothing() async throws {
        let rig = try await PhotosRig()

        // On the first progress value of the conversion, so the encoder is under way.
        let error = try await runCancelling(rig, try rig.job(.replace)) { phase, progress in
            phase == "Converting…" && progress != nil
        }

        #expect(error is CancellationError)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.store.assets == [rig.asset])
        expectLeftNothing(rig)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingAsSavingBeginsAddsNothingToPhotos() async throws {
        let rig = try await PhotosRig()

        let error = try await runCancelling(rig, try rig.job(.replace)) { phase, _ in
            phase == "Saving to Photos…"
        }

        #expect(error is CancellationError)
        #expect(rig.store.saves.isEmpty)
        #expect(rig.store.assets == [rig.asset])
        expectLeftNothing(rig)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingTheBackupDownloadEndsCancelledAndRecordsNothing() async throws {
        let rig = try await PhotosRig(hasAdjustments: true)

        let error = try await runCancelling(rig, try rig.job(.replace), backup: true) { phase, _ in
            phase == "Downloading the original for the backup…"
        }

        // Cancelled, not completed with a warning; the copy was saved before the backup, so it stays.
        #expect(error is CancellationError)
        #expect(rig.store.saves.count == 1)
        #expect(rig.backupContents.isEmpty)
        expectLeftNothing(rig)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingAnUneditedBackupCopyBeforeItStartsRecordsNothing() async throws {
        let rig = try await PhotosRig()

        // Cancelled once the new video is saved, before the backup and the record.
        let error = try await runCancelling(rig, try rig.job(.replace), backup: true) { phase, progress in
            phase == "Saving to Photos…" && progress == 1
        }

        #expect(error is CancellationError)
        #expect(rig.backupContents.isEmpty)
        expectLeftNothing(rig)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingWithAFolderDestinationLeavesTheFolderEmpty() async throws {
        let rig = try await PhotosRig()
        let folder = rig.directory.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = try rig.job(.folder(bookmark: try folder.bookmarkData()))

        let error = try await runCancelling(rig, job) { phase, progress in
            phase == "Converting…" && progress != nil
        }

        #expect(error is CancellationError)
        #expect(rig.store.saves.isEmpty)
        expectLeftNothing(rig, folder: folder)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingTheDownloadWithAFolderDestinationLeavesTheFolderEmpty() async throws {
        let rig = try await PhotosRig()
        let folder = rig.directory.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = try rig.job(.folder(bookmark: try folder.bookmarkData()))

        let error = try await runCancelling(rig, job) { phase, progress in
            phase == "Downloading from iCloud…" && (progress ?? 0) >= 0.5
        }

        #expect(error is CancellationError)
        expectLeftNothing(rig, folder: folder)
    }

    // MARK: - Changes in Photos during the run

    private func changed(_ asset: PhotoAsset, duration: Double? = nil, edited: Bool = true) -> PhotoAsset {
        PhotoAsset(
            id: asset.id, creationDate: asset.creationDate, location: asset.location, pixelSize: asset.pixelSize,
            duration: duration ?? asset.duration, isFavorite: asset.isFavorite, hasAdjustments: edited,
            originalFileName: asset.originalFileName, originalByteSize: asset.originalByteSize,
            isLocallyAvailable: false, modificationDate: Date())
    }

    @Test(.timeLimit(.minutes(2))) func anEditMadeDuringTheDownloadKeepsTheOriginalOffTheDeleteList() async throws {
        let rig = try await PhotosRig()
        let edited = changed(rig.asset)
        rig.store.beforeInputStep = { [store = rig.store] step in if step == 2 { store.assets = [edited] } }

        let state = try await rig.runner().run(try rig.job(.replace)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.warnings == ["The original changed during conversion"])
        #expect(rig.pending.all.isEmpty)
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func aTrimDuringTheDownloadDoesNotMakeAGoodCopyGetDeleted() async throws {
        let rig = try await PhotosRig()
        let trimmed = changed(rig.asset, duration: 0.5)
        rig.store.beforeInputStep = { [store = rig.store] step in if step == 2 { store.assets = [trimmed] } }

        let state = try await rig.runner().run(try rig.job(.replace)) { _ in }

        // The copy was made from the version fetched; it is checked against that one, so it stays and is not
        // removed again, and the changed original is never queued.
        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(rig.store.saves.count == 1)
        #expect(rig.store.deletedIDs.isEmpty)
        #expect(outcome.warnings == ["The original changed during conversion"])
        #expect(rig.pending.all.isEmpty)
    }

    // MARK: - Naming and space

    @Test(.timeLimit(.minutes(2))) func anEditedVideoIsNamedAfterTheOriginalInAFolder() async throws {
        let rig = try await PhotosRig(hasAdjustments: true)
        let folder = rig.directory.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let state = try await rig.runner().run(try rig.job(.folder(bookmark: try folder.bookmarkData()))) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output.lastPathComponent == "IMG_0001 (1080p).mov")
    }

    @Test(.timeLimit(.minutes(2))) func aDiskTooFullForTheDownloadFailsBeforeFetching() async throws {
        let rig = try await PhotosRig()
        let huge = PhotoAsset(
            id: rig.asset.id, pixelSize: rig.asset.pixelSize, duration: 1.0, originalFileName: "IMG_0001.MOV",
            originalByteSize: Int64.max / 4, isLocallyAvailable: false)
        rig.store.assets = [huge]

        do {
            _ = try await rig.runner().run(try rig.job()) { _ in }
            Issue.record("expected the run to throw")
        } catch {
            #expect(error is PhotosRunnerError)
            #expect(error.localizedDescription.hasPrefix("Not enough free space"))
        }
        #expect(rig.store.inputRequests.isEmpty)
        #expect(rig.workContents.isEmpty)
    }
}
