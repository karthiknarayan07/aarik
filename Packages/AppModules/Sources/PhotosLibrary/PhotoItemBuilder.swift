import AppCore
import CryptoKit
import Foundation
import LocalLibrary

/// Turns a Photos asset into a grid item.
///
/// The item's source is `.photos(localIdentifier)` and it has no file URL, so nothing that builds a file path
/// (Replace, Show in Finder, Quick Look, bookmarks, existence checks) can be handed a Photos item by mistake. Its
/// id is derived from the local identifier, so the same asset keeps the same id across scans.
/// Frame rate, codec and dynamic range come from Photos' index (`PhotosIndex`) when it could be read; without it
/// they are unknown and left out.
public enum PhotoItemBuilder {
    public static func build(_ asset: PhotoAsset) -> LibraryItem {
        build(asset, index: nil)
    }

    /// The item with what Photos' index knows about the asset: frame rate, the codec (as `video.codec` in the
    /// inventory, which the codec filter reads) and an HDR or SDR badge.
    public static func build(_ asset: PhotoAsset, index entry: PhotoIndexEntry?) -> LibraryItem {
        var inventory = MetadataInventory()
        if let codec = entry?.codec {
            inventory.items.append(
                MetadataItem(key: "video.codec", category: .video, displayName: "Codec", value: codec))
        }
        return LibraryItem(
            id: itemID(for: asset.id), source: .photos(asset.id), name: asset.originalFileName,
            byteSize: asset.originalByteSize ?? 0,
            duration: asset.duration, pixelSize: asset.pixelSize, frameRate: entry?.fps ?? 0,
            captureDate: asset.creationDate, badges: badges(asset).union(rangeBadges(entry?.hdrType)),
            isAvailable: true, inventory: inventory)
    }

    /// Photos' `ZHDRTYPE` for a video: 0 is SDR and any other value is HDR. No value in the index could be told
    /// apart as Dolby Vision (known Dolby Vision clips read 5, the only nonzero value seen), so it gives `.hdr`,
    /// never `.dolbyVision`. Unknown gives no badge.
    static func rangeBadges(_ hdrType: Int?) -> Set<MediaBadge> {
        guard let hdrType else { return [] }
        return hdrType == 0 ? [.sdr] : [.hdr]
    }

    /// The asset UUID that Photos' index uses: the part of a local identifier before the first `/`.
    public static func assetUUID(fromLocalIdentifier localIdentifier: String) -> String {
        String(localIdentifier.prefix { $0 != "/" })
    }

    /// Badges known from Photos' own metadata.
    public static func badges(_ asset: PhotoAsset) -> Set<MediaBadge> {
        var result = Set<MediaBadge>()
        if asset.subtypes.contains(.cinematic) { result.insert(.cinematic) }
        if asset.subtypes.contains(.highFrameRate) { result.insert(.sloMo) }
        if asset.subtypes.contains(.spatial) { result.insert(.spatial) }
        if asset.hasAdjustments { result.insert(.edited) }
        // Same rule as local files: the short side decides.
        if min(asset.pixelSize.width, asset.pixelSize.height) >= 2160 { result.insert(.k4) }
        return result
    }

    /// A stable id for an asset: the first 16 bytes of the SHA-256 of its local identifier, marked as a
    /// version 8 (custom, RFC 9562) UUID with the RFC 4122 variant.
    public static func itemID(for localIdentifier: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(localIdentifier.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
