import AppCore
import CryptoKit
import Foundation
import LocalLibrary

/// Turns a Photos asset into a grid item.
///
/// The item's URL is `x-photos-asset:<localIdentifier>` with the identifier percent-encoded, so a `/` in it
/// survives. Its id is derived from the local identifier, so the same asset keeps the same id across scans.
/// Frame rate, Dolby Vision and HDR are unknown until the video is inspected, so they are left out.
public enum PhotoItemBuilder {
    public static let urlScheme = "x-photos-asset"

    /// Characters left as they are in the URL (RFC 3986 unreserved); everything else is percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func build(_ asset: PhotoAsset) -> LibraryItem {
        LibraryItem(
            id: itemID(for: asset.id), url: url(for: asset.id), byteSize: asset.originalByteSize ?? 0,
            duration: asset.duration, pixelSize: asset.pixelSize, frameRate: 0, captureDate: asset.creationDate,
            badges: badges(asset), isAvailable: true, inventory: MetadataInventory())
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

    public static func url(for localIdentifier: String) -> URL {
        let encoded = localIdentifier.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "\(urlScheme):\(encoded)")!
    }

    /// The local identifier in a URL made by `url(for:)`, or nil for any other URL.
    public static func localIdentifier(from url: URL) -> String? {
        guard url.scheme?.lowercased() == urlScheme else { return nil }
        let string = url.absoluteString
        let encoded = string[string.index(string.startIndex, offsetBy: urlScheme.count + 1)...]
        guard let identifier = encoded.removingPercentEncoding, !identifier.isEmpty else { return nil }
        return identifier
    }
}
