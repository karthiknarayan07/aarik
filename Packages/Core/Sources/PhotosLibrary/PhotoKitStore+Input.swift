import AVFoundation
import Foundation
import Photos
import Synchronization

/// Getting a video's bytes out of Photos. These are the only calls that may download from iCloud, and they run only
/// for a queued job.
///
/// Measured on a real library (ADR 0002): the unedited original comes from the `.video` resource; an edited video has
/// no usable `.fullSizeVideo` for many clips, so its current version comes from an export session instead. Resource
/// types this code doesn't know (raw value 16 exists) are never matched, so they are ignored.
extension PhotoKitStore {
    /// PHPhotosError.networkAccessRequired and .networkError.
    private static let networkErrorCodes: Set<Int> = [3164, 3169]
    /// PHPhotosError.userCancelled.
    private static let userCancelledCode = 3072

    @concurrent
    public func asset(id: String) async throws -> PhotoAsset {
        let phAsset = try Self.fetchAsset(id)
        let asset = Self.makeAsset(phAsset)
        // The caption is the one attribute a listing doesn't carry; it is read here, for a single asset.
        guard #available(macOS 27, iOS 27, *), let caption = phAsset.extendedMetadata.caption, !caption.isEmpty else {
            return asset
        }
        return asset.withCaption(caption)
    }

    private static func fetchAsset(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: idFetchOptions()).firstObject else {
            throw PhotoStoreError.notInLibrary(id)
        }
        return asset
    }

    // MARK: - Original resource

    /// Streams the `.video` resource into `url` with `requestData`, not `writeData`: only `requestData` returns a
    /// request id, which is the only way to stop an iCloud download that the user cancelled.
    @concurrent
    public func writeOriginal(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        let asset = try Self.fetchAsset(id)
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video }) else {
            throw PhotoStoreError.unavailable("it has no video resource")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PhotoStoreError.unavailable("the work folder isn't writable")
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in progress(.downloading(min(max(fraction, 0), 1))) }
        let manager = PHAssetResourceManager.default()
        let transfer = ResourceTransfer(
            file: try FileHandle(forWritingTo: url), cancelRequest: { manager.cancelDataRequest($0) })
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard transfer.start(continuation) else { return }
                let requestID = manager.requestData(
                    for: resource, options: options,
                    dataReceivedHandler: { data in transfer.receive(data) },
                    completionHandler: { error in transfer.finish(error.map(Self.mapTransferError)) })
                if transfer.setID(requestID) { manager.cancelDataRequest(requestID) }
            }
        } onCancel: {
            if let requestID = transfer.cancel() { manager.cancelDataRequest(requestID) }
        }
        // A video already on this Mac reports no progress, so end the phase explicitly.
        progress(.downloading(1))
    }

    // MARK: - Edited version

    @concurrent
    public func exportCurrentVersion(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        let asset = try Self.fetchAsset(id)
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction, _, _, _ in progress(.downloading(min(max(fraction, 0), 1))) }
        let request = ExportSessionRequest()
        let manager = PHImageManager.default()
        let box: SessionBox = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SessionBox, any Error>) in
                guard request.start(continuation) else { return }
                let requestID = manager.requestExportSession(
                    forVideo: asset, options: options, exportPreset: AVAssetExportPresetPassthrough
                ) { session, info in
                    nonisolated(unsafe) let session = session
                    request.deliver(session.map(SessionBox.init), failure: Self.exportFailure(info))
                }
                if request.setID(requestID) { manager.cancelImageRequest(requestID) }
            }
        } onCancel: {
            if let requestID = request.cancel() { manager.cancelImageRequest(requestID) }
        }
        progress(.downloading(1))
        try? FileManager.default.removeItem(at: url)
        let session = box.session
        let updates = Task {
            for await state in box.session.states(updateInterval: 0.25) {
                if case .exporting(let exportProgress) = state {
                    progress(.exporting(exportProgress.fractionCompleted))
                }
            }
        }
        defer { updates.cancel() }
        do {
            try await session.export(to: url, as: .mov)
        } catch {
            throw Self.mapTransferError(error)
        }
        progress(.exporting(1))
    }

    // MARK: - Errors

    /// A transfer error as a store error: not downloaded (iCloud refused or unreachable), cancelled, or other.
    static func mapTransferError(_ error: any Error) -> any Error {
        if error is CancellationError || error is PhotoStoreError { return error }
        let nsError = error as NSError
        switch nsError.domain {
        case PHPhotosErrorDomain:
            if networkErrorCodes.contains(nsError.code) { return PhotoStoreError.downloadFailed(describe(nsError)) }
            if nsError.code == userCancelledCode { return CancellationError() }
        case NSCocoaErrorDomain:
            // A declined system confirmation can arrive as NSUserCancelledError instead.
            if nsError.code == userCancelledCode { return CancellationError() }
        case NSURLErrorDomain:
            return PhotoStoreError.downloadFailed(describe(nsError))
        default:
            break
        }
        return PhotoStoreError.unavailable(describe(nsError))
    }

    private static func describe(_ error: NSError) -> String {
        "\(error.domain) code \(error.code): \(error.localizedDescription)"
    }

    /// Why `requestExportSession` gave no session: it was cancelled, the video is in iCloud and could not be
    /// fetched (`PHImageResultIsInCloudKey`, or error 3164), or something else.
    private static func exportFailure(_ info: [AnyHashable: Any]?) -> any Error {
        if (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true { return CancellationError() }
        let error = info?[PHImageErrorKey] as? NSError
        let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true
        if inCloud || error.map({ networkErrorCodes.contains($0.code) }) == true {
            return PhotoStoreError.downloadFailed(
                error.map(describe) ?? "the video is in iCloud and was not downloaded")
        }
        return PhotoStoreError.unavailable(error.map(describe) ?? "no export session")
    }
}

/// An export session handed across tasks. PhotoKit gives it to one request and only that request's export uses it.
struct SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
}

/// One `requestExportSession` call: resumes its continuation exactly once, with the session or the reason there
/// was none, and ends it when the task is cancelled first.
final class ExportSessionRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<SessionBox, any Error>?
        var requestID: PHImageRequestID?
        var isDone = false
    }

    private let state = Mutex(State())

    /// False when the task was cancelled first; the continuation is then resumed with a cancellation.
    func start(_ continuation: CheckedContinuation<SessionBox, any Error>) -> Bool {
        let cancelled = state.withLock { state in
            if !state.isDone { state.continuation = continuation }
            return state.isDone
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        return !cancelled
    }

    /// Stores the PhotoKit request id. True when the request already ended (cancelled between `start` and now):
    /// the caller must cancel it at once, or PhotoKit keeps working.
    func setID(_ id: PHImageRequestID) -> Bool {
        state.withLock { state in
            state.requestID = id
            return state.isDone
        }
    }

    func deliver(_ box: SessionBox?, failure: @autoclosure () -> any Error) {
        let continuation: CheckedContinuation<SessionBox, any Error>? = state.withLock { state in
            guard !state.isDone else { return nil }
            state.isDone = true
            defer { state.continuation = nil }
            return state.continuation
        }
        guard let continuation else { return }
        if let box { continuation.resume(returning: box) } else { continuation.resume(throwing: failure()) }
    }

    /// Ends the request, returning the PhotoKit id to cancel, if there is one.
    func cancel() -> PHImageRequestID? {
        let (continuation, id): (CheckedContinuation<SessionBox, any Error>?, PHImageRequestID?) = state.withLock {
            state in
            let continuation = state.isDone ? nil : state.continuation
            state.isDone = true
            state.continuation = nil
            return (continuation, state.requestID)
        }
        continuation?.resume(throwing: CancellationError())
        return id
    }
}

/// One `requestData` transfer into a file: bytes are appended as they arrive, and the continuation is resumed
/// exactly once, when it completes, fails to write (the request is then cancelled), or is cancelled.
///
/// The file is written and closed under one lock, so a close never lands in the middle of a write.
final class ResourceTransfer: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var requestID: PHAssetResourceDataRequestID?
        var isDone = false
        var isClosed = false
    }

    private let state = Mutex(State())
    private let file: FileHandle
    private let cancelRequest: @Sendable (PHAssetResourceDataRequestID) -> Void

    init(file: FileHandle, cancelRequest: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void) {
        self.file = file
        self.cancelRequest = cancelRequest
    }

    /// False when the task was cancelled first; the continuation is then resumed with a cancellation.
    func start(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        let cancelled = state.withLock { state in
            if !state.isDone { state.continuation = continuation }
            return state.isDone
        }
        if cancelled {
            closeFile()
            continuation.resume(throwing: CancellationError())
        }
        return !cancelled
    }

    /// Stores the PhotoKit request id. True when the transfer already ended (cancelled or failed between `start`
    /// and now): the caller must cancel the request at once, or PhotoKit keeps downloading.
    func setID(_ id: PHAssetResourceDataRequestID) -> Bool {
        state.withLock { state in
            state.requestID = id
            return state.isDone
        }
    }

    /// Called on PhotoKit's serial queue, in order.
    func receive(_ data: Data) {
        let failure: (any Error)? = state.withLock { state in
            guard !state.isDone, !state.isClosed else { return nil }
            do {
                try file.write(contentsOf: data)
                return nil
            } catch {
                return error
            }
        }
        if let failure { fail(failure) }
    }

    /// A write failed (the disk is full, say): stop the download and report it.
    private func fail(_ error: any Error) {
        let (continuation, id): (CheckedContinuation<Void, any Error>?, PHAssetResourceDataRequestID?) = state.withLock
        {
            state in
            guard !state.isDone else { return (nil, nil) }
            state.isDone = true
            defer { state.continuation = nil }
            return (state.continuation, state.requestID)
        }
        closeFile()
        continuation?.resume(throwing: PhotoStoreError.unavailable(error.localizedDescription))
        if let id { cancelRequest(id) }
    }

    func finish(_ error: (any Error)?) {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard !state.isDone else { return nil }
            state.isDone = true
            defer { state.continuation = nil }
            return state.continuation
        }
        closeFile()
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    /// Ends the transfer, returning the PhotoKit id to cancel, if there is one yet.
    func cancel() -> PHAssetResourceDataRequestID? {
        let (continuation, id): (CheckedContinuation<Void, any Error>?, PHAssetResourceDataRequestID?) = state.withLock
        {
            state in
            let continuation = state.isDone ? nil : state.continuation
            state.isDone = true
            state.continuation = nil
            return (continuation, state.requestID)
        }
        closeFile()
        continuation?.resume(throwing: CancellationError())
        return id
    }

    private func closeFile() {
        state.withLock { state in
            guard !state.isClosed else { return }
            state.isClosed = true
            try? file.close()
        }
    }
}
