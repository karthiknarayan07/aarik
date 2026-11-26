import AppCore
import Foundation
import MediaEngine
import PhotosLibrary
import Synchronization

@testable import Convert

/// A fake Photos library holding one video whose bytes are a real clip, a work folder and a pending-deletions
/// file, all in one temporary directory.
final class PhotosRig: Sendable {
    let directory: URL
    let store: FakePhotoStore
    let asset: PhotoAsset
    let clip: URL
    let workFolder: WorkFolder
    let pending: PendingDeletions
    let backup: URL

    static let spec = RunnerFixture.spec

    init(
        subtypes: PhotoSubtypes = [], hasAdjustments: Bool = false, savedDuration: Double? = nil,
        albums: [String] = [], audio: Bool = true
    ) async throws {
        let clip = try await RunnerFixture.source(name: "IMG_0001.MOV", audio: audio)
        directory = clip.deletingLastPathComponent()
        self.clip = clip
        workFolder = WorkFolder(root: directory.appending(path: "Work", directoryHint: .isDirectory))
        pending = PendingDeletions(directory: directory)
        backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        asset = PhotoAsset(
            id: "6F1B8A2C-1D3E-4F5A-9B7C-0E2D4F6A8B1C/L0/001",
            creationDate: Date(timeIntervalSince1970: 1_750_000_000),
            location: PhotoLocation(latitude: 48.85, longitude: 2.35, altitude: 35),
            pixelSize: CGSize(width: 2560, height: 1440), duration: 1.0, isFavorite: true,
            hasAdjustments: hasAdjustments, subtypes: subtypes, originalFileName: "IMG_0001.MOV",
            originalByteSize: RunnerFixture.size(clip), isLocallyAvailable: false)
        store = FakePhotoStore(assets: [asset])
        store.originalFiles[asset.id] = clip
        store.currentVersionFiles[asset.id] = clip
        store.savedDuration = savedDuration ?? 1.0
        store.albums[asset.id] = albums
        store.existingAlbums = Set(albums)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func runner(core: ConvertRunner = RunnerFixture.runner(), backup: Bool = false) -> PhotosConvertRunner {
        let folder = self.backup
        return PhotosConvertRunner(
            store: store, workFolder: workFolder, pendingDeletions: pending, core: core,
            originalsBackup: { backup ? OriginalsBackup(folder: folder) : nil })
    }

    func job(
        _ destination: PhotosDestination = .newAsset, id: String? = nil, predictedLost: [String]? = nil
    ) throws -> Job {
        let settings = ConvertJobSettings(
            preset: .balanced, saveTo: .nextToOriginal, custom: Self.spec, predictedLost: predictedLost,
            photosDestination: destination, photosFileName: "IMG_0001.MOV")
        return Job(
            toolID: ConvertTool.photosToolID, source: PhotoAssetURL.url(for: id ?? asset.id), sourceBookmark: Data(),
            settings: try JSONEncoder().encode(settings))
    }

    /// Job folders left in the work folder.
    var workContents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: workFolder.root.path)) ?? []
    }

    var backupContents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backup.path)) ?? []).sorted()
    }
}

/// What a run reported: phases in order, with the progress at each change.
final class RunLog: Sendable {
    private let state = Mutex((phases: [String](), progress: [Double]()))

    var phases: [String] { state.withLock { $0.phases } }
    var progress: [Double] { state.withLock { $0.progress } }

    func run(_ runner: PhotosConvertRunner, _ job: Job) async throws -> JobState {
        try await runner.run(
            job,
            progress: { value in self.state.withLock { $0.progress.append(value) } },
            phase: { phase in
                guard let phase else { return }
                self.state.withLock { if $0.phases.last != phase { $0.phases.append(phase) } }
            })
    }
}
