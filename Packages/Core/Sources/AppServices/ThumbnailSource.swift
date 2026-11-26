import CoreGraphics
import Foundation
import LocalLibrary
import PhotosLibrary

/// Where a grid item's poster comes from: a frame of the file, or the thumbnail Photos has on this Mac. Both are
/// kept in one `ThumbnailCache`; nothing is downloaded from iCloud.
public struct ThumbnailSource: Sendable {
    public let cache: ThumbnailCache
    public let photos: any PhotoStore

    public init(cache: ThumbnailCache, photos: any PhotoStore) {
        self.cache = cache
        self.photos = photos
    }

    public func image(for item: LibraryItem, maxPixel: Int) async -> CGImage? {
        switch item.source {
        case .file(let url):
            return await cache.thumbnail(for: url, maxPixel: maxPixel)
        case .photos(let identifier):
            let size = Self.size(for: item.pixelSize, maxPixel: maxPixel)
            let photos = photos
            // The identifier and modification date are the key (an edited video gets a fresh poster); no string is built.
            return await cache.thumbnail(forKey: identifier, modified: item.modifiedDate, maxPixel: maxPixel) {
                await photos.thumbnail(for: identifier, size: size)
            }
        }
    }

    /// Poster for a queued or finished job URL (either a file URL or an `x-photos-asset:` address).
    public func image(forJobURL url: URL, maxPixel: Int) async -> CGImage? {
        if url.isFileURL {
            return await cache.thumbnail(for: url, maxPixel: maxPixel)
        }
        guard let identifier = PhotoAssetURL.identifier(from: url) else { return nil }
        let size = CGSize(width: maxPixel, height: maxPixel)
        let photos = photos
        return await cache.thumbnail(forKey: identifier, modified: nil, maxPixel: maxPixel) {
            await photos.thumbnail(for: identifier, size: size)
        }
    }

    /// The poster when it is already in memory, without waiting: a tile that scrolls back in shows it at once.
    /// Only Photos videos are kept under a key that needs no file access, so a file's poster is nil here.
    public func cachedImage(for item: LibraryItem, maxPixel: Int) -> CGImage? {
        guard case .photos(let identifier) = item.source else { return nil }
        return cache.cachedImage(forKey: identifier, modified: item.modifiedDate, maxPixel: maxPixel)
    }

    /// The video's shape with its longer side at `maxPixel`; a square when its size isn't known.
    public static func size(for pixelSize: CGSize, maxPixel: Int) -> CGSize {
        let longer = max(pixelSize.width, pixelSize.height)
        guard longer > 0 else { return CGSize(width: maxPixel, height: maxPixel) }
        let scale = Double(maxPixel) / longer
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }
}
