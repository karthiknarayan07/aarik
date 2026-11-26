import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import LocalLibrary

@Suite struct ThumbnailCancellationTests {
    private static func image() -> CGImage? {
        CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    /// A grid fling: 300 tiles ask for a poster and give up at once. Their work must not run on to the end,
    /// or the posters the screen shows wait behind 300 dead requests.
    @Test func requestsNobodyWaitsForAnyMoreStopTheirWork() async {
        let cache = ThumbnailCache()
        let started = Mutex(0)
        let finished = Mutex(0)
        let produce: @Sendable () async -> CGImage? = {
            started.withLock { $0 += 1 }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return nil }
            finished.withLock { $0 += 1 }
            return Self.image()
        }
        let tiles = (0..<300).map { index in
            Task { await cache.thumbnail(forKey: "p\(index)", maxPixel: 320, produce: produce) }
        }
        while started.withLock({ $0 }) < 300 { await Task.yield() }
        for tile in tiles { tile.cancel() }
        for tile in tiles { _ = await tile.value }
        try? await Task.sleep(for: .milliseconds(1_200))
        print("THUMBNAIL dead requests that ran to the end: \(finished.withLock { $0 }) of 300")
        #expect(finished.withLock { $0 } == 0)
        #expect(await cache.cachedCount == 0)
    }

    @Test func workContinuesWhileAnyCallerIsStillWaiting() async {
        let cache = ThumbnailCache()
        let produce: @Sendable () async -> CGImage? = {
            try? await Task.sleep(for: .milliseconds(200))
            return Task.isCancelled ? nil : Self.image()
        }
        let first = Task { await cache.thumbnail(forKey: "A", maxPixel: 320, produce: produce) }
        let second = Task { await cache.thumbnail(forKey: "A", maxPixel: 320, produce: produce) }
        try? await Task.sleep(for: .milliseconds(50))
        first.cancel()
        #expect(await second.value != nil)
        #expect(await cache.cachedCount == 1)
    }

    @Test func aFinishedPosterCanBeReadWithoutWaiting() async {
        let cache = ThumbnailCache()
        let date = Date(timeIntervalSince1970: 5)
        #expect(cache.cachedImage(forKey: "A", modified: date, maxPixel: 320) == nil)
        _ = await cache.thumbnail(forKey: "A", modified: date, maxPixel: 320) { Self.image() }
        #expect(cache.cachedImage(forKey: "A", modified: date, maxPixel: 320) != nil)
        // A different modification date (an edited video) or size is a different poster.
        #expect(cache.cachedImage(forKey: "A", modified: Date(timeIntervalSince1970: 6), maxPixel: 320) == nil)
        #expect(cache.cachedImage(forKey: "A", modified: date, maxPixel: 640) == nil)
    }

    @Test func aCancelledCallerLeavesNothingStuckForTheNextOne() async {
        let cache = ThumbnailCache()
        let slow: @Sendable () async -> CGImage? = {
            try? await Task.sleep(for: .seconds(5))
            return Task.isCancelled ? nil : Self.image()
        }
        let gone = Task { await cache.thumbnail(forKey: "A", maxPixel: 320, produce: slow) }
        try? await Task.sleep(for: .milliseconds(50))
        gone.cancel()
        _ = await gone.value
        #expect(await cache.thumbnail(forKey: "A", maxPixel: 320) { Self.image() } != nil)
    }
}
