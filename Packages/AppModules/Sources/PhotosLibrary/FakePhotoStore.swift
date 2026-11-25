import CoreGraphics
import Foundation
import Synchronization

/// An in-memory `PhotoStore` for tests and previews. Set its contents directly; `emitChange()` plays a library
/// change.
public final class FakePhotoStore: PhotoStore {
    private struct State {
        var assets: [PhotoAsset] = []
        var authorization: PhotoAuthorization = .authorized
        var authorizationOnRequest: PhotoAuthorization = .authorized
        var requestCount = 0
        var albums: [String: [String]] = [:]
        var thumbnails: [String: CGImage] = [:]
        var videosError: PhotoStoreError?
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init(assets: [PhotoAsset] = [], authorization: PhotoAuthorization = .authorized) {
        state.withLock {
            $0.assets = assets
            $0.authorization = authorization
        }
    }

    /// The videos `videos()` returns, in order.
    public var assets: [PhotoAsset] {
        get { state.withLock { $0.assets } }
        set { state.withLock { $0.assets = newValue } }
    }

    public var currentAuthorization: PhotoAuthorization {
        get { state.withLock { $0.authorization } }
        set { state.withLock { $0.authorization = newValue } }
    }

    /// What the user "answers" when `requestAuthorization()` is called while access is not determined.
    public var authorizationOnRequest: PhotoAuthorization {
        get { state.withLock { $0.authorizationOnRequest } }
        set { state.withLock { $0.authorizationOnRequest = newValue } }
    }

    /// How many times `requestAuthorization()` was called.
    public var requestCount: Int { state.withLock { $0.requestCount } }

    /// Album identifiers by asset identifier.
    public var albums: [String: [String]] {
        get { state.withLock { $0.albums } }
        set { state.withLock { $0.albums = newValue } }
    }

    public var thumbnails: [String: CGImage] {
        get { state.withLock { $0.thumbnails } }
        set { state.withLock { $0.thumbnails = newValue } }
    }

    /// When set, `videos()` throws it.
    public var videosError: PhotoStoreError? {
        get { state.withLock { $0.videosError } }
        set { state.withLock { $0.videosError = newValue } }
    }

    /// Number of open `changes()` streams.
    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// Tells every open `changes()` stream that the library changed.
    public func emitChange() {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for continuation in subscribers { continuation.yield() }
    }

    // MARK: - PhotoStore

    public func authorization() async -> PhotoAuthorization { currentAuthorization }

    public func requestAuthorization() async -> PhotoAuthorization {
        state.withLock {
            $0.requestCount += 1
            if $0.authorization == .notDetermined { $0.authorization = $0.authorizationOnRequest }
            return $0.authorization
        }
    }

    public func videos() async throws -> [PhotoAsset] {
        let (assets, authorization, error) = state.withLock { ($0.assets, $0.authorization, $0.videosError) }
        guard authorization.allowsReading else { throw PhotoStoreError.notAuthorized }
        if let error { throw error }
        return assets
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        state.withLock { $0.subscribers[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: key) }
        }
        return stream
    }

    public func albums(containing id: String) async throws -> [String] {
        let (known, albums) = state.withLock { state in (state.assets.contains { $0.id == id }, state.albums[id]) }
        guard known else { throw PhotoStoreError.notInLibrary(id) }
        return albums ?? []
    }

    public func thumbnail(for id: String, size: CGSize) async -> CGImage? {
        state.withLock { $0.thumbnails[id] }
    }
}
