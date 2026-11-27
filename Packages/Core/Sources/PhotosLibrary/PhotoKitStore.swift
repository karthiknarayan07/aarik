import AppCore
import CoreGraphics
import CoreLocation
import Foundation
import Photos
import Synchronization
import UniformTypeIdentifiers

/// The real `PhotoStore`, backed by PhotoKit. Reads metadata only: listing, albums and thumbnails never download
/// from iCloud.
public final class PhotoKitStore: PhotoStore {
    /// Assets read per batch when listing; each batch runs as its own background task.
    private static let batchSize = 256

    private let includeHidden: Bool
    /// What the last listing fetched: the assets by local identifier (so a thumbnail request doesn't fetch the asset
    /// again) and the fetch result (so a library change that touches no video is told apart from one that does).
    private final class Listing: Sendable {
        struct State: @unchecked Sendable {
            var assets: [String: PHAsset] = [:]
            var result: PHFetchResult<PHAsset>?
        }

        let state = Mutex(State())
    }

    private let listing = Listing()
    /// One caching manager for every poster: it shares work between requests for the same asset.
    private let imageManager = PHCachingImageManager()

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

    /// One fetch for all user-library videos, newest first.
    @concurrent
    public func videos() async throws -> [PhotoAsset] {
        try await fetchAssets(predicate: NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
    }

    /// One fetch for all user-library videos and images, newest first. Never downloads from iCloud.
    @concurrent
    public func mediaAssets() async throws -> [PhotoAsset] {
        try await fetchAssets(
            predicate: NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue))
    }

    @concurrent
    private func fetchAssets(predicate: NSPredicate) async throws -> [PhotoAsset] {
        guard await authorization().allowsReading else { throw PhotoStoreError.notAuthorized }
        let options = PHFetchOptions()
        options.predicate = predicate
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = includeHidden
        let result = PHAsset.fetchAssets(with: options)
        let count = result.count
        let batchSize = Self.batchSize
        listing.state.withLock { $0.result = result }
        let objects = Mutex<[String: PHAsset]>([:])
        defer { listing.state.withLock { $0.assets = objects.withLock { $0 } } }
        return try await withThrowingTaskGroup(of: (Int, [PhotoAsset]).self) { group in
            for start in stride(from: 0, to: count, by: batchSize) {
                group.addTask {
                    try Task.checkCancellation()
                    let range = start..<min(start + batchSize, count)
                    let assets = autoreleasepool {
                        let fetched = result.objects(at: IndexSet(integersIn: range))
                        objects.withLock { map in
                            for asset in fetched { map[asset.localIdentifier] = asset }
                        }
                        return fetched.map(Self.makeAsset)
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
        let mediaKind: MediaKind = asset.mediaType == .image ? .image : .video
        let primaryType: PHAssetResourceType = mediaKind == .image ? .photo : .video
        let original = resources.first { $0.type == primaryType } ?? resources.first
        let pairedVideo =
            mediaKind == .image
            ? (resources.first { $0.type == .fullSizePairedVideo } ?? resources.first { $0.type == .pairedVideo })
            : nil
        var subtypes = subtypes(asset.mediaSubtypes)
        if mediaKind == .image,
            resources.contains(where: { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true })
        {
            subtypes.insert(.rawPhoto)
        }
        return PhotoAsset(
            id: asset.localIdentifier, mediaKind: mediaKind, creationDate: asset.creationDate,
            location: location(asset.location),
            pixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight), duration: asset.duration,
            isFavorite: asset.isFavorite, isHidden: asset.isHidden, hasAdjustments: asset.hasAdjustments,
            subtypes: subtypes, originalFileName: original.map(fileName) ?? "",
            originalByteSize: original.flatMap(byteSize), pairedVideoByteSize: pairedVideo.flatMap(byteSize),
            isLocallyAvailable: original.flatMap(isLocallyAvailable),
            modificationDate: asset.modificationDate)
    }

    private static func subtypes(_ subtypes: PHAssetMediaSubtype) -> PhotoSubtypes {
        var result: PhotoSubtypes = []
        if subtypes.contains(.videoHighFrameRate) { result.insert(.highFrameRate) }
        if subtypes.contains(.videoCinematic) { result.insert(.cinematic) }
        if subtypes.contains(.spatialMedia) { result.insert(.spatial) }
        if subtypes.contains(.videoTimelapse) { result.insert(.timelapse) }
        if subtypes.contains(.videoStreamed) { result.insert(.streamed) }
        if subtypes.contains(.photoLive) { result.insert(.livePhoto) }
        if subtypes.contains(.photoDepthEffect) { result.insert(.depthEffect) }
        if subtypes.contains(.photoHDR) { result.insert(.hdrPhoto) }
        return result
    }

    static func location(_ location: CLLocation?) -> PhotoLocation? {
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        return PhotoLocation(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil)
    }

    // MARK: - Resource fields

    private static func fileName(_ resource: PHAssetResource) -> String {
        if #available(macOS 27, iOS 27, *) {
            if let name = resource.filename { return name }
        }
        return resource.originalFilename
    }

    /// The public `dataSize` where the OS has it, else the `fileSize` key PhotoKit has long had.
    private static func byteSize(_ resource: PHAssetResource) -> Int64? {
        if #available(macOS 27, iOS 27, *) {
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
        let observer = ChangeObserver(continuation) { [listing] change in
            // Before the first listing every change counts. After it, only a change to the videos does: an
            // unrelated edit would otherwise rebuild the whole list.
            guard let result = listing.state.withLock({ $0.result }) else { return true }
            return change.changeDetails(for: result) != nil
        }
        PHPhotoLibrary.shared().register(observer)
        continuation.onTermination = { _ in PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        return stream
    }

    /// Options for fetching a known asset by local identifier, including hidden ones so verifying or deleting a
    /// hidden copy works.
    static func idFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        return options
    }

    // MARK: - Albums

    @concurrent
    public func albums(containing id: String) async throws -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: Self.idFetchOptions()).firstObject
        else {
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
        let known = listing.state.withLock { $0.assets[id] }
        guard
            let asset = known
                ?? PHAsset.fetchAssets(withLocalIdentifiers: [id], options: Self.idFetchOptions()).firstObject
        else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.version = .current
        let request = ThumbnailRequest()
        let manager = imageManager
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.start(continuation) else { return }
                let requestID = manager.requestImage(
                    for: asset, targetSize: size, contentMode: .aspectFill, options: options
                ) { image, info in
                    let cgImage = image?.platformCGImage
                    let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                    request.deliver(cgImage, isFinal: !degraded)
                }
                request.setID(requestID)
            }
        } onCancel: {
            if let requestID = request.cancel() { manager.cancelImageRequest(requestID) }
        }
        // Photos hands back an image that is decoded when first drawn, which would happen on the main thread in the
        // middle of a scroll; decode it here, off the main thread.
        return image.flatMap { $0.predecoded() }
    }
}

extension CGImage {
    /// The same picture as an image whose pixels are already in memory (itself when a bitmap can't be made).
    fileprivate func predecoded() -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return self }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? self
    }
}

/// Bridges PhotoKit's change callback (called on a PhotoKit queue) to an async stream.
private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let isRelevant: @Sendable (PHChange) -> Bool

    init(_ continuation: AsyncStream<Void>.Continuation, isRelevant: @escaping @Sendable (PHChange) -> Bool) {
        self.continuation = continuation
        self.isRelevant = isRelevant
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        if isRelevant(changeInstance) { continuation.yield() }
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
