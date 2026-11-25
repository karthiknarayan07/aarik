import AVFoundation
import AarikCore
import Foundation

/// Reads every file-level metadata item (no allow-list) as `qt.` items.
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
        var result: [MetadataItem] = []
        for item in try await asset.load(.metadata) {
            let keyString = keyString(of: item)
            let key =
                if item.keySpace == .quickTimeMetadata {
                    "qt.\(keyString)"
                } else {
                    "qt.\(item.keySpace?.rawValue ?? "unknown")/\(keyString)"
                }
            result.append(
                MetadataItem(
                    key: key, category: category(of: keyString),
                    displayName: displayName(of: keyString), value: try await value(of: item)))
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
