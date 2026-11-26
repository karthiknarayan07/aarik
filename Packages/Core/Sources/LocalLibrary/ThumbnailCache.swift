import AVFoundation
import CoreGraphics
import Foundation
import Synchronization

/// Poster frames for the grid, generated on demand and kept in memory by file, modification time and size, or
/// by a caller's own key (Photos videos, whose thumbnails come from Photos).
///
/// A grid asks for a poster the moment a tile appears and gives up when it scrolls away, so a request that nobody
/// waits for any more is cancelled (and its work with it) instead of queueing behind the ones that are still needed.
/// Finished posters can also be read without waiting (`cachedImage`), so a tile that comes back on screen shows its
/// poster in its first frame.
public actor ThumbnailCache {
    fileprivate struct Key: Hashable, Sendable {
        let path: String
        let modified: Date?
        let maxPixel: Int
    }

    /// The finished posters, least recently used first. Behind a lock so a tile can read it without an actor hop.
    private final class Store: Sendable {
        private struct State {
            var images: [Key: CGImage] = [:]
            var recency: [Key] = []
        }

        private let state = Mutex(State())
        let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        var count: Int { state.withLock { $0.images.count } }

        /// Reading refreshes recency only when `touch` is true; a tile's per-frame peek leaves the order alone.
        func image(for key: Key, touch: Bool) -> CGImage? {
            state.withLock { state in
                guard let image = state.images[key] else { return nil }
                if touch, state.recency.last != key {
                    state.recency.removeAll { $0 == key }
                    state.recency.append(key)
                }
                return image
            }
        }

        func store(_ image: CGImage, for key: Key) {
            state.withLock { state in
                state.images[key] = image
                state.recency.removeAll { $0 == key }
                state.recency.append(key)
                while state.recency.count > limit { state.images[state.recency.removeFirst()] = nil }
            }
        }
    }

    /// One production of a poster, shared by every caller waiting for it. It is cancelled when the last of them
    /// stops waiting.
    private final class Flight: Sendable {
        private struct State {
            var waiters = 0
            var isCancelled = false
        }

        let task: Task<CGImage?, Never>
        private let state = Mutex(State())

        init(task: Task<CGImage?, Never>) {
            self.task = task
        }

        var isCancelled: Bool { state.withLock { $0.isCancelled } }

        /// False when the work was already cancelled: the caller starts a new flight instead.
        func join() -> Bool {
            state.withLock { state in
                guard !state.isCancelled else { return false }
                state.waiters += 1
                return true
            }
        }

        /// One waiter stops waiting. When it gave up (rather than got its answer) and it was the last, the work
        /// is cancelled.
        func leave(gaveUp: Bool) {
            let cancel = state.withLock { state -> Bool in
                state.waiters -= 1
                guard gaveUp, state.waiters <= 0, !state.isCancelled else { return false }
                state.isCancelled = true
                return true
            }
            if cancel { task.cancel() }
        }
    }

    /// A caller's place in a flight, left exactly once however the call ends.
    private final class Waiter: Sendable {
        private let flight: Flight
        private let left = Mutex(false)

        init?(joining flight: Flight) {
            guard flight.join() else { return nil }
            self.flight = flight
        }

        func leave(gaveUp: Bool) {
            let first = left.withLock { left -> Bool in
                defer { left = true }
                return !left
            }
            if first { flight.leave(gaveUp: gaveUp) }
        }
    }

    private let store: Store
    private var inFlight: [Key: Flight] = [:]

    public init(limit: Int = 300) {
        store = Store(limit: max(1, limit))
    }

    /// Number of thumbnails held in memory.
    public var cachedCount: Int { store.count }

    /// A thumbnail whose longer side is at most `maxPixel`, in display orientation; nil if none can be made.
    public func thumbnail(for url: URL, maxPixel: Int = 320) async -> CGImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let key = Key(path: url.path, modified: modified, maxPixel: maxPixel)
        return await image(for: key) { await Self.generate(url, maxPixel: maxPixel) }
    }

    /// A thumbnail kept under `key`, made by `produce` the first time (and again after it left the cache or
    /// returned nil). Calls for the same key and size that overlap share one `produce`, which is cancelled when
    /// every call waiting for it has been cancelled.
    public func thumbnail(
        forKey key: String, modified: Date? = nil, maxPixel: Int = 320,
        produce: @escaping @Sendable () async -> CGImage?
    ) async -> CGImage? {
        await image(for: Key(path: key, modified: modified, maxPixel: maxPixel), produce: produce)
    }

    /// The finished thumbnail for a key, if it is in memory, without waiting for anything.
    public nonisolated func cachedImage(forKey key: String, modified: Date? = nil, maxPixel: Int = 320) -> CGImage? {
        store.image(for: Key(path: key, modified: modified, maxPixel: maxPixel), touch: false)
    }

    private func image(for key: Key, produce: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        if let image = store.image(for: key, touch: true) { return image }
        var joined = inFlight[key].flatMap { flight in Waiter(joining: flight).map { (flight, $0) } }
        if joined == nil {
            let flight = Flight(task: Task { await produce() })
            inFlight[key] = flight
            joined = Waiter(joining: flight).map { (flight, $0) }
        }
        guard let (flight, waiter) = joined else { return nil }
        let image = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            waiter.leave(gaveUp: true)
        }
        waiter.leave(gaveUp: false)
        if inFlight[key] === flight { inFlight[key] = nil }
        if let image, !flight.isCancelled { store.store(image, for: key) }
        return image
    }

    private static func generate(_ url: URL, maxPixel: Int) async -> CGImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: seconds.isFinite && seconds > 0 ? min(1, seconds / 2) : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
