import AVFoundation
import AarikCore
import CryptoKit
import Foundation

/// Turns a media file into a normalized, comparable `MetadataInventory`.
public struct MediaInspector: Sendable {
    public init() {}

    /// File-level metadata, then per-track items in track order, then file-system attributes.
    public func inventory(of url: URL) async throws -> MetadataInventory {
        let asset = AVURLAsset(url: url)
        var items = try await AssetMetadataReader.items(of: asset)
        items += try await TrackInspector.items(of: asset)
        items += try FileAttributes.read(url)
        return MetadataInventory(items: items)
    }
}

/// Lowercase hex SHA-256 of `data`.
func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Renders a four-character code, for example `'hvc1'` → `"hvc1"`.
func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08x", code)
}
