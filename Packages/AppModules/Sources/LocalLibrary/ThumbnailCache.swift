import AVFoundation
import CoreGraphics
import Foundation

/// Poster frames for the grid, generated on demand and kept in memory by file, modification time and size.
public actor ThumbnailCache {
    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let maxPixel: Int
    }

    private let limit: Int
    private var images: [Key: CGImage] = [:]
    private var recency: [Key] = []
    private var inFlight: [Key: Task<CGImage?, Never>] = [:]

    public init(limit: Int = 300) {
        self.limit = max(1, limit)
    }

    /// Number of thumbnails held in memory.
    public var cachedCount: Int { images.count }

    /// A thumbnail whose longer side is at most `maxPixel`, in display orientation; nil if none can be made.
    public func thumbnail(for url: URL, maxPixel: Int = 320) async -> CGImage? {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let key = Key(path: url.path, modified: modified, maxPixel: maxPixel)
        if let image = images[key] {
            touch(key)
            return image
        }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await Self.generate(url, maxPixel: maxPixel) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { store(image, for: key) }
        return image
    }

    private func store(_ image: CGImage, for key: Key) {
        images[key] = image
        touch(key)
        while recency.count > limit { images[recency.removeFirst()] = nil }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func generate(_ url: URL, maxPixel: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: seconds.isFinite && seconds > 0 ? min(1, seconds / 2) : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
