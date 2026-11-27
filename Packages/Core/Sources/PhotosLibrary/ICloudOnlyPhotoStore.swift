import CoreGraphics
import Foundation
import Synchronization

/// A `PhotoStore` for tests whose videos live only in iCloud, like the originals of an optimised iPhone library.
/// The first fetch of an asset downloads it (progress on the way, then it is available on this device); a fetch of
/// an asset marked with `failDownload` writes a partial file, reports half way and throws, like a connection that
/// dropped. Everything else forwards to the `FakePhotoStore` it wraps, so `base.originalFiles` and the like still work.
public final class ICloudOnlyPhotoStore: PhotoStore {
    public let base: FakePhotoStore
    private let state = Mutex(State())

    private struct State {
        var downloaded: Set<String> = []
        var failures: [String: PhotoStoreError] = [:]
        var downloadAttempts: [String] = []
    }

    public init(assets: [PhotoAsset] = [], authorization: PhotoAuthorization = .authorized) {
        base = FakePhotoStore(assets: assets, authorization: authorization)
    }

    /// Makes the download of `id` fail half way with `error`, every time it is tried.
    public func failDownload(of id: String, with error: PhotoStoreError = .downloadFailed("offline")) {
        state.withLock { $0.failures[id] = error }
    }

    /// Lets the download of `id` work again.
    public func repairDownload(of id: String) {
        state.withLock { _ = $0.failures.removeValue(forKey: id) }
    }

    /// Identifiers whose original is on this device now.
    public var downloadedIDs: Set<String> { state.withLock { $0.downloaded } }

    /// Every download started, in order (including failed ones).
    public var downloadAttempts: [String] { state.withLock { $0.downloadAttempts } }

    /// The asset as the library reports it: only in iCloud until it has been downloaded.
    private func reported(_ asset: PhotoAsset) -> PhotoAsset {
        let local = state.withLock { $0.downloaded.contains(asset.id) }
        return PhotoAsset(
            id: asset.id, mediaKind: asset.mediaKind, creationDate: asset.creationDate, location: asset.location,
            pixelSize: asset.pixelSize, duration: asset.duration, isFavorite: asset.isFavorite,
            isHidden: asset.isHidden, hasAdjustments: asset.hasAdjustments, subtypes: asset.subtypes,
            originalFileName: asset.originalFileName, originalByteSize: asset.originalByteSize,
            pairedVideoByteSize: asset.pairedVideoByteSize, isLocallyAvailable: local,
            modificationDate: asset.modificationDate, caption: asset.caption)
    }

    // MARK: - PhotoStore

    public func authorization() async -> PhotoAuthorization { await base.authorization() }
    public func requestAuthorization() async -> PhotoAuthorization { await base.requestAuthorization() }
    public func videos() async throws -> [PhotoAsset] { try await base.videos().map(reported) }
    public func mediaAssets() async throws -> [PhotoAsset] { try await base.mediaAssets().map(reported) }
    public func changes() -> AsyncStream<Void> { base.changes() }
    public func albums(containing id: String) async throws -> [String] { try await base.albums(containing: id) }
    public func thumbnail(for id: String, size: CGSize) async -> CGImage? { await base.thumbnail(for: id, size: size) }
    public func asset(id: String) async throws -> PhotoAsset { reported(try await base.asset(id: id)) }
    public func saveVideo(_ request: PhotoSaveRequest) async throws -> String { try await base.saveVideo(request) }
    public func saveImage(_ request: PhotoSaveRequest) async throws -> String { try await base.saveImage(request) }
    public func deleteAssets(ids: [String]) async throws { try await base.deleteAssets(ids: ids) }

    public func writeOriginal(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        try await download(id: id, to: url, progress: progress) {
            try await self.base.writeOriginal(id: id, to: url, progress: progress)
        }
    }

    public func exportCurrentVersion(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        try await download(id: id, to: url, progress: progress) {
            try await self.base.exportCurrentVersion(id: id, to: url, progress: progress)
        }
    }

    public func writePairedVideo(
        id: String, to url: URL, isEdited: Bool, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        try await download(id: id, to: url, progress: progress) {
            try await self.base.writePairedVideo(id: id, to: url, isEdited: isEdited, progress: progress)
        }
    }

    private func download(
        id: String, to url: URL, progress: @Sendable (FetchProgress) -> Void,
        fetch: () async throws -> Void
    ) async throws {
        let (failure, needsDownload) = state.withLock { state in
            let needs = !state.downloaded.contains(id)
            if needs { state.downloadAttempts.append(id) }
            return (needs ? state.failures[id] : nil, needs)
        }
        if let failure {
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x2A, count: 100))
            progress(.downloading(0.5))
            throw failure
        }
        try await fetch()
        if needsDownload { state.withLock { _ = $0.downloaded.insert(id) } }
    }
}
