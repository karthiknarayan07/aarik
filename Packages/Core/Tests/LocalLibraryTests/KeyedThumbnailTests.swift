import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import LocalLibrary

@Suite struct KeyedThumbnailTests {
    private static func image() -> CGImage? {
        CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    @Test func producesOnceAndServesFromMemory() async {
        let cache = ThumbnailCache()
        let calls = Mutex(0)
        let produce: @Sendable () async -> CGImage? = {
            calls.withLock { $0 += 1 }
            return Self.image()
        }
        #expect(await cache.thumbnail(forKey: "photos:A", maxPixel: 320, produce: produce) != nil)
        #expect(await cache.thumbnail(forKey: "photos:A", maxPixel: 320, produce: produce) != nil)
        #expect(calls.withLock { $0 } == 1)
        #expect(await cache.cachedCount == 1)
    }

    @Test func eachKeyAndSizeIsItsOwnEntry() async {
        let cache = ThumbnailCache()
        _ = await cache.thumbnail(forKey: "photos:A", maxPixel: 320) { Self.image() }
        _ = await cache.thumbnail(forKey: "photos:A", maxPixel: 640) { Self.image() }
        _ = await cache.thumbnail(forKey: "photos:B", maxPixel: 320) { Self.image() }
        #expect(await cache.cachedCount == 3)
    }

    @Test func missingImagesAreNotCached() async {
        let cache = ThumbnailCache()
        let calls = Mutex(0)
        let produce: @Sendable () async -> CGImage? = {
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(await cache.thumbnail(forKey: "photos:A", maxPixel: 320, produce: produce) == nil)
        #expect(await cache.thumbnail(forKey: "photos:A", maxPixel: 320, produce: produce) == nil)
        #expect(calls.withLock { $0 } == 2)
        #expect(await cache.cachedCount == 0)
    }

    @Test func oldestEntriesLeaveWhenFull() async {
        let cache = ThumbnailCache(limit: 2)
        for key in ["A", "B", "C"] { _ = await cache.thumbnail(forKey: key, maxPixel: 320) { Self.image() } }
        #expect(await cache.cachedCount == 2)
    }
}
