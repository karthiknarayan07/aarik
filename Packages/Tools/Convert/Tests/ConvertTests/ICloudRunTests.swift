import AppCore
import Foundation
import MediaTestSupport
import PhotosLibrary
import Testing

@testable import Convert

/// Videos that live only in iCloud, run through the real queue and the real Photos runner: each run reads
/// "Downloading from iCloud" and then "Converting", and a download that fails fails just that video.
@Suite struct ICloudRunTests {
    private func cloudAsset(_ id: String, like asset: PhotoAsset) -> PhotoAsset {
        PhotoAsset(
            id: id, creationDate: asset.creationDate, location: asset.location, pixelSize: asset.pixelSize,
            duration: asset.duration, hasAdjustments: false, originalFileName: asset.originalFileName,
            originalByteSize: asset.originalByteSize, isLocallyAvailable: false)
    }

    /// A download takes a moment, as a real one does: the queue publishes progress alone at most every 100 ms, so an
    /// instant fake would show only the stage after it.
    private func slowDownloads(_ store: ICloudOnlyPhotoStore) {
        store.base.beforeInputStep = { _ in try? await Task.sleep(for: .milliseconds(120)) }
    }

    /// Runs `ids` (queued in order) to the end, returning every snapshot of every job.
    private func run(
        rig: PhotosRig, store: ICloudOnlyPhotoStore, ids: [String]
    ) async throws -> (final: [Job], snapshots: [[Job]]) {
        let runner = PhotosConvertRunner(
            store: store, workFolder: rig.workFolder, pendingDeletions: rig.pending, core: RunnerFixture.runner(),
            originalsBackup: { nil })
        let queue = JobQueue(
            store: JobStore(directory: rig.directory.appending(path: "Queue")),
            runners: [ConvertTool.photosToolID: runner])
        // Subscribe before queueing, or the first stages are over before anyone looks.
        let updates = await queue.updates()
        await queue.enqueue(try ids.map { try rig.job(.newAsset, id: $0) })
        var snapshots: [[Job]] = []
        for await snapshot in updates {
            snapshots.append(snapshot)
            let finished = snapshot.filter {
                switch $0.state {
                case .completed, .keptAsIs, .failed: true
                case .queued, .running: false
                }
            }
            if finished.count == ids.count { break }
        }
        let final = await queue.jobs
        await queue.shutdown()
        return (final, snapshots)
    }

    /// The distinct phases the job with this source showed while running, in order.
    private func phases(of id: String, in snapshots: [[Job]]) -> [String] {
        var seen: [String] = []
        for snapshot in snapshots {
            guard let job = snapshot.first(where: { $0.source == PhotoAssetURL.url(for: id) }),
                case .running = job.state, let phase = job.phase, seen.last != phase
            else { continue }
            seen.append(phase)
        }
        return seen
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func theRunMovesFromDownloadingToConvertingAndThenTheVideoIsOnTheDevice() async throws {
        let rig = try await PhotosRig()
        let store = ICloudOnlyPhotoStore(assets: [cloudAsset("A/L0/001", like: rig.asset)])
        store.base.originalFiles["A/L0/001"] = rig.clip
        store.base.savedDuration = 1.0
        slowDownloads(store)

        let result = try await run(rig: rig, store: store, ids: ["A/L0/001"])

        #expect(phases(of: "A/L0/001", in: result.snapshots).prefix(2) == ["Downloading from iCloud…", "Converting…"])
        let sawDownloadStatus = result.snapshots.flatMap { $0 }.contains { $0.isDownloading }
        #expect(sawDownloadStatus)
        guard case .completed = result.final[0].state else {
            Issue.record("expected the iCloud video to convert, got \(result.final[0].state)")
            return
        }
        #expect(store.downloadedIDs == ["A/L0/001"])
        #expect(store.base.saves.count == 1)
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func aFailedDownloadFailsJustThatVideoAndTheNextOneStillConverts() async throws {
        let rig = try await PhotosRig()
        let failing = "A/L0/001"
        let working = "B/L0/001"
        let store = ICloudOnlyPhotoStore(assets: [
            cloudAsset(failing, like: rig.asset), cloudAsset(working, like: rig.asset),
        ])
        for id in [failing, working] { store.base.originalFiles[id] = rig.clip }
        store.base.savedDuration = 1.0
        slowDownloads(store)
        store.failDownload(of: failing)

        let result = try await run(rig: rig, store: store, ids: [failing, working])

        let first = try #require(result.final.first { $0.source == PhotoAssetURL.url(for: failing) })
        let second = try #require(result.final.first { $0.source == PhotoAssetURL.url(for: working) })
        guard case .failed(let reason, let code) = first.state else {
            Issue.record("expected the failed download to fail its video, got \(first.state)")
            return
        }
        #expect(reason.hasPrefix("Couldn't download from iCloud"))
        #expect(code == .iCloudDownloadFailed)
        #expect(!phases(of: failing, in: result.snapshots).contains("Converting…"))
        guard case .completed = second.state else {
            Issue.record("expected the other video to convert, got \(second.state)")
            return
        }
        #expect(phases(of: working, in: result.snapshots).prefix(2) == ["Downloading from iCloud…", "Converting…"])
        #expect(store.base.saves.count == 1)
        #expect(store.base.deletedIDs.isEmpty)
        #expect(rig.workContents.isEmpty)
    }
}
