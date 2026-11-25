import CoreGraphics
import LocalLibrary
import PhotosLibrary

/// Where a grid item's poster comes from: a frame of the file, or the thumbnail Photos has on this Mac. Both are
/// kept in one `ThumbnailCache`; nothing is downloaded from iCloud.
struct ThumbnailSource: Sendable {
    let cache: ThumbnailCache
    let photos: any PhotoStore

    func image(for item: LibraryItem, maxPixel: Int) async -> CGImage? {
        switch item.source {
        case .file(let url):
            return await cache.thumbnail(for: url, maxPixel: maxPixel)
        case .photos(let identifier):
            let size = Self.size(for: item.pixelSize, maxPixel: maxPixel)
            let photos = photos
            let key = PhotoItemBuilder.thumbnailKey(for: item) ?? "photos:\(identifier)"
            return await cache.thumbnail(forKey: key, maxPixel: maxPixel) {
                await photos.thumbnail(for: identifier, size: size)
            }
        }
    }

    /// The video's shape with its longer side at `maxPixel`; a square when its size isn't known.
    static func size(for pixelSize: CGSize, maxPixel: Int) -> CGSize {
        let longer = max(pixelSize.width, pixelSize.height)
        guard longer > 0 else { return CGSize(width: maxPixel, height: maxPixel) }
        let scale = Double(maxPixel) / longer
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }
}
