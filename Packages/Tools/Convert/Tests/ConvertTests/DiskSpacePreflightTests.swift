import AarikCore
import Foundation
import MediaEngine
import PhotosLibrary
import Synchronization
import Testing

@testable import Convert

/// The free-space rule before a job writes anything: the estimated output, plus the download for a Photos video,
/// plus 1 GB, on every volume involved. All with a fake disk; the real one is never asked.
@Suite struct DiskSpacePreflightTests {
    private static let gb: Int64 = 1_000_000_000
    private static let spec = RunnerFixture.spec

    private func roomy() -> DiskSpaceCheck { DiskSpaceCheck(provider: FakeDiskSpace(available: 100 * Self.gb)) }

    private func full(_ name: String = "Macintosh HD", available: Int64 = 200_000_000) -> DiskSpaceCheck {
        DiskSpaceCheck(provider: FakeDiskSpace(available: available, name: name))
    }

    private func runner(
        _ diskSpace: DiskSpaceCheck, backup: URL? = nil, trash: @escaping ConvertRunner.Trasher = { $0 }
    ) -> ConvertRunner {
        ConvertRunner(
            trash: trash, originalsBackup: { backup.map { OriginalsBackup(folder: $0) } }, diskSpace: diskSpace)
    }

    private func settings(_ saveTo: SaveDestination = .nextToOriginal) -> ConvertJobSettings {
        ConvertJobSettings(preset: .balanced, saveTo: saveTo, custom: Self.spec)
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - Files

    @Test(.timeLimit(.minutes(5))) func aFullDiskFailsAFileJobBeforeAnythingIsWritten() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov", audio: false)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try names(in: directory)
        let original = try Data(contentsOf: source)

        do {
            _ = try await runner(full()).run(try RunnerFixture.job(source, settings())) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            #expect(error.volumeName == "Macintosh HD")
            #expect(error.availableBytes == 200_000_000)
            #expect(error.neededBytes > Self.gb)
            #expect(error.localizedDescription.hasPrefix("Not enough free space on Macintosh HD (needs about "))
            #expect(error.localizedDescription.hasSuffix(", has 200 MB)"))
        }

        #expect(try names(in: directory) == before)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(.timeLimit(.minutes(5))) func retryWorksOnceThereIsRoom() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov", audio: false)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try RunnerFixture.job(source, settings())

        await #expect(throws: NotEnoughSpaceError.self) { try await runner(full()).run(job) { _ in } }
        let state = try await runner(roomy()).run(job) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output == directory.appending(path: "clip (1080p).mov"))
    }

    @Test(.timeLimit(.minutes(5))) func theOutputFolderIsTheVolumeThatIsChecked() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov", audio: false)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "External", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // The source's own volume is roomy; the chosen folder's is not.
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: destination, name: "Travel SSD", available: 300_000_000)
        let bookmark = try destination.bookmarkData()

        do {
            _ = try await runner(DiskSpaceCheck(provider: disk))
                .run(try RunnerFixture.job(source, settings(.folder(bookmark: bookmark)))) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            #expect(error.volumeName == "Travel SSD")
        }
        #expect(try names(in: destination).isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aFullBackupVolumeFailsTheJobBeforeTheEncode() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov", audio: false)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let before = try names(in: directory)
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: backup, name: "Backup Drive", available: 300_000_000)
        let trashed = Mutex(false)

        do {
            _ = try await runner(
                DiskSpaceCheck(provider: disk), backup: backup,
                trash: { url in
                    trashed.withLock { $0 = true }
                    return url
                }
            ).run(try RunnerFixture.job(source, settings(.replace))) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            #expect(error.volumeName == "Backup Drive")
        }
        // Nothing was encoded, backed up or trashed.
        #expect(!trashed.withLock { $0 })
        #expect(try names(in: directory) == before)
        #expect(try names(in: backup).isEmpty)
    }

    @Test func theBackupCopyChecksItsVolumeJustBeforeCopying() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "clip.mov")
        try Data("original".utf8).write(to: original)
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: backup, name: "Backup Drive", available: 300_000_000)

        #expect(throws: OriginalsBackupError.notEnoughSpace) {
            try runner(DiskSpaceCheck(provider: disk)).backUp(original, byteSize: 8, into: backup)
        }
        #expect(try names(in: backup).isEmpty)
    }

    // MARK: - Photos

    private func photosRunner(_ rig: PhotosRig, _ diskSpace: DiskSpaceCheck, backup: Bool = false)
        -> PhotosConvertRunner
    {
        rig.runner(core: runner(diskSpace), backup: backup)
    }

    @Test(.timeLimit(.minutes(5))) func aFullDiskStopsAPhotosJobBeforeTheDownload() async throws {
        let rig = try await PhotosRig(audio: false)

        do {
            _ = try await photosRunner(rig, full()).run(try rig.job()) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            // The download (the clip's size) and its converted copy, plus the margin.
            #expect(error.neededBytes > Self.gb + (rig.asset.originalByteSize ?? 0))
            #expect(error.availableBytes == 200_000_000)
        }
        #expect(rig.store.inputRequests.isEmpty)
        // Not even the job's folder was made.
        #expect(!FileManager.default.fileExists(atPath: rig.workFolder.root.path))
    }

    @Test(.timeLimit(.minutes(5))) func theDownloadSizeCountsOnTheWorkVolume() async throws {
        let rig = try await PhotosRig(audio: false)
        // Room for the margin and the small converted copy, but not for a download as big as this one.
        let big = PhotoAsset(
            id: rig.asset.id, pixelSize: rig.asset.pixelSize, duration: 1.0, originalFileName: "IMG_0001.MOV",
            originalByteSize: 5 * Self.gb, isLocallyAvailable: false)
        rig.store.assets = [big]
        let disk = FakeDiskSpace(available: 3 * Self.gb)

        await #expect(throws: NotEnoughSpaceError.self) {
            try await photosRunner(rig, DiskSpaceCheck(provider: disk)).run(try rig.job()) { _ in }
        }
        #expect(rig.store.inputRequests.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func thePhotosLibraryVolumeIsCheckedBeforeTheDownload() async throws {
        let rig = try await PhotosRig(audio: false)
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: PhotosConvertRunner.photosLibraryLocation, name: "Library Disk", available: 300_000_000)

        do {
            _ = try await photosRunner(rig, DiskSpaceCheck(provider: disk)).run(try rig.job()) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            #expect(error.volumeName == "Library Disk")
        }
        #expect(rig.store.inputRequests.isEmpty)
        #expect(rig.store.saves.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func theLibraryVolumeIsCheckedAgainWithTheRealSizeBeforeSaving() async throws {
        let rig = try await PhotosRig(audio: false)
        // Photos doesn't report the size, so only the check after conversion can catch it.
        rig.store.assets = [
            PhotoAsset(
                id: rig.asset.id, pixelSize: rig.asset.pixelSize, duration: 1.0, originalFileName: "IMG_0001.MOV",
                isLocallyAvailable: false)
        ]
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: PhotosConvertRunner.photosLibraryLocation, name: "Library Disk", available: 300_000_000)

        await #expect(throws: NotEnoughSpaceError.self) {
            try await photosRunner(rig, DiskSpaceCheck(provider: disk)).run(try rig.job()) { _ in }
        }
        #expect(rig.store.saves.isEmpty)
        #expect(rig.workContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aFolderDestinationIsCheckedOnItsOwnVolume() async throws {
        let rig = try await PhotosRig(audio: false)
        let folder = rig.directory.appending(path: "Out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: folder, name: "Travel SSD", available: 300_000_000)

        do {
            _ = try await photosRunner(rig, DiskSpaceCheck(provider: disk))
                .run(try rig.job(.folder(bookmark: try folder.bookmarkData()))) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            #expect(error.volumeName == "Travel SSD")
        }
        #expect(rig.store.inputRequests.isEmpty)
        #expect(try names(in: folder).isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func anEditedVideoWithABackupCountsTheSecondFetch() async throws {
        let rig = try await PhotosRig(hasAdjustments: true, audio: false)
        let size = try #require(rig.asset.originalByteSize)
        // The Work volume has room for the margin, the video and its smaller converted copy, but not for a second
        // fetch of the original (the backup's source) on top.
        let work = rig.workFolder.root
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: work, name: "Macintosh HD", available: Self.gb + size * 2)

        // Without a backup it fits.
        let state = try await photosRunner(rig, DiskSpaceCheck(provider: disk)).run(try rig.job(.replace)) { _ in }
        guard case .completed = state else {
            Issue.record("expected completed, got \(state)")
            return
        }

        await #expect(throws: NotEnoughSpaceError.self) {
            try await photosRunner(rig, DiskSpaceCheck(provider: disk), backup: true).run(try rig.job(.replace)) {
                _ in
            }
        }
        #expect(rig.backupContents.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func theBackupCheckUsesTheOriginalsSizeNotTheEditedRenderings() async throws {
        let rig = try await PhotosRig(hasAdjustments: true, audio: false)
        // The edited rendering (the first fetch) is big; the original is small.
        let original = try await RunnerFixture.smallSource(name: "original.mov", audio: false)
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        rig.store.originalFiles[rig.asset.id] = original
        let renderingSize = try #require(RunnerFixture.size(rig.clip))
        let originalSize = try #require(RunnerFixture.size(original))
        try #require(renderingSize > originalSize + 1000)
        // Photos' own record of the original is the small size, so the up-front estimate fits.
        rig.store.assets = [
            PhotoAsset(
                id: rig.asset.id, creationDate: rig.asset.creationDate, location: rig.asset.location,
                pixelSize: rig.asset.pixelSize, duration: rig.asset.duration, isFavorite: rig.asset.isFavorite,
                hasAdjustments: true, originalFileName: rig.asset.originalFileName, originalByteSize: originalSize,
                isLocallyAvailable: false, modificationDate: rig.asset.modificationDate)
        ]
        // The backup volume has room for the margin and the original, but not for the rendering's size.
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: rig.backup, name: "Backup Drive", available: Self.gb + originalSize + 500)

        let state = try await photosRunner(rig, DiskSpaceCheck(provider: disk), backup: true)
            .run(try rig.job(.replace)) { _ in }

        guard case .completed = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(rig.backupContents == ["IMG_0001.MOV"])
    }

    @Test(.timeLimit(.minutes(5))) func theBackupVolumeIsCheckedBeforeAPhotosDownload() async throws {
        let rig = try await PhotosRig(audio: false)
        let disk = FakeDiskSpace(available: 100 * Self.gb)
        disk.setVolume(at: rig.backup, name: "Backup Drive", available: 300_000_000)

        do {
            _ = try await photosRunner(rig, DiskSpaceCheck(provider: disk), backup: true)
                .run(try rig.job(.replace)) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            #expect(error.volumeName == "Backup Drive")
        }
        #expect(rig.store.inputRequests.isEmpty)
        #expect(rig.pending.all.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func theExactEstimateIsCheckedOnceTheVideoIsRead() async throws {
        let rig = try await PhotosRig(audio: false)
        // Photos doesn't say how big the video is, so nothing can be checked before the download.
        rig.store.assets = [
            PhotoAsset(
                id: rig.asset.id, pixelSize: rig.asset.pixelSize, duration: 1.0, originalFileName: "IMG_0001.MOV",
                isLocallyAvailable: false)
        ]

        do {
            _ = try await photosRunner(rig, full()).run(try rig.job()) { _ in }
            Issue.record("expected the run to throw")
        } catch let error as NotEnoughSpaceError {
            #expect(error.localizedDescription.hasPrefix("Not enough free space on Macintosh HD"))
        }
        // The download happened, and was cleaned up; nothing was converted or saved.
        #expect(rig.store.inputRequests.count == 1)
        #expect(rig.workContents.isEmpty)
        #expect(rig.store.saves.isEmpty)
    }

    @Test(.timeLimit(.minutes(5))) func aPhotosJobRetriesAfterAFullDisk() async throws {
        let rig = try await PhotosRig(audio: false)
        let job = try rig.job()

        await #expect(throws: NotEnoughSpaceError.self) { try await photosRunner(rig, full()).run(job) { _ in } }
        let state = try await photosRunner(rig, roomy()).run(job) { _ in }

        guard case .completed = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
    }
}
