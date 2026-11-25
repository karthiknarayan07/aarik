import AVFoundation
import AarikCore
import Foundation

/// Reads every file-level metadata item (no allow-list) as `qt.` items, and track-level items the same way.
enum AssetMetadataReader {
    private static let displayNames: [String: String] = [
        "com.apple.quicktime.make": "Camera make",
        "com.apple.quicktime.model": "Camera model",
        "com.apple.quicktime.software": "Software",
        "com.apple.quicktime.camera.lens_model": "Lens model",
        "com.apple.quicktime.location.ISO6709": "Location",
        "com.apple.quicktime.creationdate": "Creation date",
        "com.apple.quicktime.content.identifier": "Live Photo identifier",
    ]

    static func items(of asset: AVAsset) async throws -> [MetadataItem] {
        try await items(from: asset.load(.metadata), keyPrefix: "qt.") { keyString in
            (category(of: keyString), displayName(of: keyString))
        }
    }

    /// Track-level items as `trackmeta.<trackIndex>.<key>`, with the same key and value normalization as file level.
    static func trackItems(of track: AVAssetTrack, trackIndex: Int) async throws -> [MetadataItem] {
        try await items(from: track.load(.metadata), keyPrefix: "trackmeta.\(trackIndex).") { keyString in
            (.track, "Track \(trackIndex + 1) \(displayName(of: keyString))")
        }
    }

    /// `<keyPrefix><key>` for the QuickTime metadata key space, `<keyPrefix><keySpace>/<key>` for any other.
    private static func items(
        from metadata: [AVMetadataItem], keyPrefix: String,
        describe: (String) -> (category: MetadataCategory, displayName: String)
    ) async throws -> [MetadataItem] {
        var result: [MetadataItem] = []
        for item in metadata {
            let keyString = keyString(of: item)
            let key =
                if item.keySpace == .quickTimeMetadata {
                    keyPrefix + keyString
                } else {
                    "\(keyPrefix)\(item.keySpace?.rawValue ?? "unknown")/\(keyString)"
                }
            let (category, displayName) = describe(keyString)
            result.append(
                MetadataItem(key: key, category: category, displayName: displayName, value: try await value(of: item)))
        }
        return result
    }

    private static func keyString(of item: AVMetadataItem) -> String {
        switch item.key {
        case let string as String: string
        case let number as NSNumber: fourCC(number.uint32Value)
        case let other?: "\(other)"
        case nil: item.identifier?.rawValue ?? "unknown"
        }
    }

    private static func value(of item: AVMetadataItem) async throws -> String {
        if let string = try await item.load(.stringValue) { return string }
        if let number = try await item.load(.numberValue) { return number.stringValue }
        if let date = try await item.load(.dateValue) { return date.ISO8601Format() }
        if let data = try await item.load(.dataValue) { return sha256Hex(data) }
        return "present"
    }

    static func category(of key: String) -> MetadataCategory {
        let lower = key.lowercased()
        if lower.contains("location") { return .location }
        if lower.contains("creationdate") { return .date }
        if ["make", "model", "software", "lens"].contains(where: lower.contains) { return .camera }
        return .other
    }

    static func displayName(of key: String) -> String {
        displayNames[key] ?? key.split(separator: ".").last.map(String.init) ?? key
    }
}
