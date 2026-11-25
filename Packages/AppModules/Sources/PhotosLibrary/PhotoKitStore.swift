import AppKit
import CoreGraphics
import CoreLocation
import Foundation
import Photos
import Synchronization

/// The real `PhotoStore`, backed by PhotoKit. Reads metadata only: listing, albums and thumbnails never download
/// from iCloud.
public final class PhotoKitStore: PhotoStore {
    /// Assets read per batch when listing; each batch runs as its own background task.
    private static let batchSize = 256

    private let includeHidden: Bool

    /// Hidden videos are left out unless `includeHidden` is true, as in Photos' own Library view.
    public init(includeHidden: Bool = false) {
        self.includeHidden = includeHidden
    }

    // MARK: - Authorization

    public func authorization() async -> PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> PhotoAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .denied
        }
    }

    // MARK: - Listing

    /// One fetch for all user-library videos, newest first. Resources (name, size, local or iCloud) are read in
    /// batches off the main actor.
    @concurrent
    public func videos() async throws -> [PhotoAsset] {
        guard await authorization().allowsReading else { throw PhotoStoreError.notAuthorized }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = includeHidden
        let result = PHAsset.fetchAssets(with: .video, options: options)
        let count = result.count
        let batchSize = Self.batchSize
        return try await withThrowingTaskGroup(of: (Int, [PhotoAsset]).self) { group in
            for start in stride(from: 0, to: count, by: batchSize) {
                group.addTask {
                    try Task.checkCancellation()
                    let range = start..<min(start + batchSize, count)
                    let assets = autoreleasepool {
                        result.objects(at: IndexSet(integersIn: range)).map(Self.makeAsset)
                    }
                    return (start, assets)
                }
            }
            var batches: [(Int, [PhotoAsset])] = []
            for try await batch in group { batches.append(batch) }
            return batches.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    static func makeAsset(_ asset: PHAsset) -> PhotoAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .video } ?? resources.first
        return PhotoAsset(
            id: asset.localIdentifier, creationDate: asset.creationDate, location: location(asset.location),
            pixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight), duration: asset.duration,
            isFavorite: asset.isFavorite, isHidden: asset.isHidden, hasAdjustments: asset.hasAdjustments,
            subtypes: subtypes(asset.mediaSubtypes), originalFileName: original.map(fileName) ?? "",
            originalByteSize: original.flatMap(byteSize), isLocallyAvailable: original.flatMap(isLocallyAvailable),
            modificationDate: asset.modificationDate)
    }

    private static func subtypes(_ subtypes: PHAssetMediaSubtype) -> PhotoSubtypes {
        var result: PhotoSubtypes = []
        if subtypes.contains(.videoHighFrameRate) { result.insert(.highFrameRate) }
        if subtypes.contains(.videoCinematic) { result.insert(.cinematic) }
        if subtypes.contains(.spatialMedia) { result.insert(.spatial) }
        if subtypes.contains(.videoTimelapse) { result.insert(.timelapse) }
        if subtypes.contains(.videoStreamed) { result.insert(.streamed) }
        return result
    }

    private static func location(_ location: CLLocation?) -> PhotoLocation? {
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        return PhotoLocation(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            altitude: location.altitude)
    }

    // MARK: - Resource fields

    private static func fileName(_ resource: PHAssetResource) -> String {
        if #available(macOS 27, *) {
            if let name = resource.filename { return name }
        }
        return resource.originalFilename
    }

    /// The public `dataSize` where the OS has it, else the `fileSize` key PhotoKit has long had.
    private static func byteSize(_ resource: PHAssetResource) -> Int64? {
        if #available(macOS 27, *) {
            if let size = resource.dataSize { return Int64(size) }
        }
        return (value(resource, key: "fileSize") as? NSNumber).map { $0.int64Value }
    }

    private static func isLocallyAvailable(_ resource: PHAssetResource) -> Bool? {
        (value(resource, key: "locallyAvailable") as? NSNumber).map(\.boolValue)
    }

    /// Reads a key that isn't public API, or nil when the object has no getter for it. Reading a missing key
    /// would raise an Objective-C exception, so the getter is checked first (`key`, or `isKey` for a Boolean).
    private static func value(_ object: NSObject, key: String) -> Any? {
        let booleanGetter = "is" + key.prefix(1).uppercased() + key.dropFirst()
        guard object.responds(to: NSSelectorFromString(key)) || object.responds(to: NSSelectorFromString(booleanGetter))
        else { return nil }
        return object.value(forKey: key)
    }

    // MARK: - Changes

    /// Streams library changes. Access must already be granted: registering earlier could show the system prompt,
    /// so before that the stream finishes at once.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let status = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard status.allowsReading else {
            continuation.finish()
            return stream
        }
        let observer = ChangeObserver(continuation)
        PHPhotoLibrary.shared().register(observer)
        continuation.onTermination = { _ in PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        return stream
    }

    // MARK: - Albums

    @concurrent
    public func albums(containing id: String) async throws -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoStoreError.notInLibrary(id)
        }
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var identifiers: [String] = []
        collections.enumerateObjects { collection, _, _ in
            if collection.assetCollectionSubtype == .albumRegular { identifiers.append(collection.localIdentifier) }
        }
        return identifiers
    }

    // MARK: - Thumbnails

    /// The best image Photos has on this Mac: the final image, else the last low-quality one it delivered.
    @concurrent
    public func thumbnail(for id: String, size: CGSize) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.version = .current
        let request = ThumbnailRequest()
        let manager = PHImageManager.default()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.start(continuation) else { return }
                let requestID = manager.requestImage(
                    for: asset, targetSize: size, contentMode: .aspectFill, options: options
                ) { image, info in
                    let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                    request.deliver(cgImage, isFinal: !degraded)
                }
                request.setID(requestID)
            }
        } onCancel: {
            if let requestID = request.cancel() { manager.cancelImageRequest(requestID) }
        }
    }
}

/// Bridges PhotoKit's change callback (called on a PhotoKit queue) to an async stream.
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        continuation.yield()
    }
}

/// One thumbnail request: resumes its continuation exactly once, with the final image or the best one so far.
private final class ThumbnailRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<CGImage?, Never>?
        var latest: CGImage?
        var requestID: PHImageRequestID?
        var isDone = false
    }

    private let state = Mutex(State())

    /// False when the task was cancelled first; the continuation is then resumed with nil.
    func start(_ continuation: CheckedContinuation<CGImage?, Never>) -> Bool {
        let cancelled = state.withLock { state in
            if !state.isDone { state.continuation = continuation }
            return state.isDone
        }
        if cancelled { continuation.resume(returning: nil) }
        return !cancelled
    }

    func setID(_ id: PHImageRequestID) {
        state.withLock { $0.requestID = id }
    }

    func deliver(_ image: CGImage?, isFinal: Bool) {
        let resume: (CheckedContinuation<CGImage?, Never>, CGImage?)? = state.withLock { state in
            if let image { state.latest = image }
            guard isFinal, !state.isDone, let continuation = state.continuation else { return nil }
            state.isDone = true
            state.continuation = nil
            return (continuation, state.latest)
        }
        if let (continuation, image) = resume { continuation.resume(returning: image) }
    }

    /// Ends the request with what it has, returning the PhotoKit id to cancel, if any.
    func cancel() -> PHImageRequestID? {
        let (continuation, image, id): (CheckedContinuation<CGImage?, Never>?, CGImage?, PHImageRequestID?) =
            state.withLock { state in
                let continuation = state.isDone ? nil : state.continuation
                state.isDone = true
                state.continuation = nil
                return (continuation, state.latest, state.requestID)
            }
        continuation?.resume(returning: image)
        return id
    }
}
