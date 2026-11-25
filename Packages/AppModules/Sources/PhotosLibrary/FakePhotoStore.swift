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
        var videosCalls = 0
        var beforeVideos: (@Sendable () async -> Void)?
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
        var inputBytes = 1_000
        var inputSteps = 4
        var inputError: PhotoStoreError?
        var beforeInputStep: (@Sendable (Int) async -> Void)?
        var inputRequests: [InputRequest] = []
    }

    /// What a test can see of a fetch the fake served.
    public struct InputRequest: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// `writeOriginal`: the original resource.
            case original
            /// `exportCurrentVersion`: the edited version's export.
            case currentVersion
        }

        public let id: String
        public let kind: Kind
        public let url: URL
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

    /// How many times `videos()` was called.
    public var videosCallCount: Int { state.withLock { $0.videosCalls } }

    /// Runs at the start of every `videos()` call, so a test can hold a fetch while the library "changes".
    public var beforeVideos: (@Sendable () async -> Void)? {
        get { state.withLock { $0.beforeVideos } }
        set { state.withLock { $0.beforeVideos = newValue } }
    }

    /// Size of the file a fetch writes, in bytes (default 1000).
    public var inputBytes: Int {
        get { state.withLock { $0.inputBytes } }
        set { state.withLock { $0.inputBytes = max(newValue, 1) } }
    }

    /// How many chunks (and progress steps) a fetch takes (default 4).
    public var inputSteps: Int {
        get { state.withLock { $0.inputSteps } }
        set { state.withLock { $0.inputSteps = max(newValue, 1) } }
    }

    /// When set, a fetch writes its first chunk and then throws it, like a download that broke off.
    public var inputError: PhotoStoreError? {
        get { state.withLock { $0.inputError } }
        set { state.withLock { $0.inputError = newValue } }
    }

    /// Runs after each chunk of a fetch (with the 1-based step), so a test can hold a fetch half way, with a
    /// partial file on disk, and cancel it.
    public var beforeInputStep: (@Sendable (Int) async -> Void)? {
        get { state.withLock { $0.beforeInputStep } }
        set { state.withLock { $0.beforeInputStep = newValue } }
    }

    /// The fetches started so far, in order.
    public var inputRequests: [InputRequest] { state.withLock { $0.inputRequests } }

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
        let hook = state.withLock { state in
            state.videosCalls += 1
            return state.beforeVideos
        }
        await hook?()
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

    public func asset(id: String) async throws -> PhotoAsset {
        guard let asset = state.withLock({ state in state.assets.first { $0.id == id } }) else {
            throw PhotoStoreError.notInLibrary(id)
        }
        return asset
    }

    public func writeOriginal(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        try await simulate(id: id, kind: .original, url: url, progress: progress)
    }

    public func exportCurrentVersion(
        id: String, to url: URL, progress: @escaping @Sendable (FetchProgress) -> Void
    ) async throws {
        try await simulate(id: id, kind: .currentVersion, url: url, progress: progress)
    }

    /// Writes `inputBytes` in `inputSteps` chunks, reporting download progress, then (for an export) export
    /// progress. The file exists from the first chunk on, so a failed or cancelled fetch leaves a partial one.
    private func simulate(
        id: String, kind: InputRequest.Kind, url: URL, progress: @Sendable (FetchProgress) -> Void
    ) async throws {
        let (known, bytes, steps, error, hook) = state.withLock { state in
            state.inputRequests.append(InputRequest(id: id, kind: kind, url: url))
            return (
                state.assets.contains { $0.id == id }, state.inputBytes, state.inputSteps, state.inputError,
                state.beforeInputStep
            )
        }
        guard known else { throw PhotoStoreError.notInLibrary(id) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PhotoStoreError.unavailable("the file couldn't be created")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0x2A, count: max(bytes / steps, 1))
        for step in 1...steps {
            try handle.write(contentsOf: chunk)
            progress(.downloading(Double(step) / Double(steps)))
            await hook?(step)
            try Task.checkCancellation()
            if step == 1, let error { throw error }
        }
        if kind == .currentVersion {
            for step in 1...steps {
                progress(.exporting(Double(step) / Double(steps)))
                try Task.checkCancellation()
            }
        }
    }
}
