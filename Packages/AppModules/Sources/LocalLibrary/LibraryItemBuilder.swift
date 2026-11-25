import AppCore
import CoreGraphics
import Foundation

/// Derives a `LibraryItem` (size, rates, date, badges) from a metadata inventory.
enum LibraryItemBuilder {
    private static let hdrTransferFunctions: Set<String> = ["ITU_R_2100_HLG", "SMPTE_ST_2084_PQ"]

    /// The item for a file, or nil when the inventory has no video dimensions (not a video file).
    static func build(
        url: URL, inventory: MetadataInventory, byteSize: Int64, id: UUID = UUID(), isAvailable: Bool = true
    ) -> LibraryItem? {
        guard let stored = size(inventory["video.dimensions"]?.value) else { return nil }
        let pixelSize = rotatesQuarterTurn(inventory["video.transform"]?.value) ? stored.swapped : stored
        let frameRate = Double(inventory["video.frameRate"]?.value ?? "") ?? 0
        let duration = (Double(inventory["video.duration"]?.value ?? "") ?? 0) / 1000
        return LibraryItem(
            id: id, url: url, byteSize: byteSize, duration: duration, pixelSize: pixelSize, frameRate: frameRate,
            captureDate: captureDate(inventory),
            badges: badges(inventory, pixelSize: pixelSize, frameRate: frameRate, url: url),
            isAvailable: isAvailable, inventory: inventory)
    }

    // MARK: - Badges

    private static func badges(
        _ inventory: MetadataInventory, pixelSize: CGSize, frameRate: Double, url: URL
    ) -> Set<MediaBadge> {
        var result = Set<MediaBadge>()
        let dolbyVision = inventory["hdr.dolbyVision"] != nil
        let hdr = inventory["video.transferFunction"].map { hdrTransferFunctions.contains($0.value) } ?? false
        if dolbyVision { result.insert(.dolbyVision) }
        if hdr { result.insert(.hdr) }
        if !dolbyVision && !hdr { result.insert(.sdr) }
        if min(pixelSize.width, pixelSize.height) >= 2160 { result.insert(.k4) }
        if isCinematic(inventory) { result.insert(.cinematic) }
        if frameRate >= 100 { result.insert(.sloMo) }
        if inventory["hdr.stereo"] != nil { result.insert(.spatial) }
        if hasEditSidecar(url) { result.insert(.edited) }
        return result
    }

    /// An auxiliary video track (the disparity or depth track, which the inspector lists as `track.<n>.kind`)
    /// or a timed cinematic-video metadata track.
    private static func isCinematic(_ inventory: MetadataInventory) -> Bool {
        inventory.items.contains { item in
            if item.key.hasPrefix("track."), item.key.hasSuffix(".kind") { return item.value.hasPrefix("vide/") }
            return item.key.hasPrefix("timed.") && item.key.localizedCaseInsensitiveContains("cinematic-video")
        }
    }

    /// Photos keeps edits of `IMG_1234.MOV` in a sibling `IMG_1234.AAE`, or `IMG_O1234.AAE` for an edited copy.
    private static func hasEditSidecar(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        var stems = [stem]
        if stem.hasPrefix("IMG_") { stems.append("IMG_O" + stem.dropFirst(4)) }
        let names = Set(stems.flatMap { ["\($0).AAE", "\($0).aae"] })
        return names.contains { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    // MARK: - Fields

    private static func size(_ value: String?) -> CGSize? {
        guard let parts = value?.split(separator: "x"), parts.count == 2,
            let width = Double(parts[0]), let height = Double(parts[1])
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// True for a 90 or 270 degree preferred transform (`a,b,c,d,tx,ty` with a == d == 0).
    private static func rotatesQuarterTurn(_ value: String?) -> Bool {
        let parts = value?.split(separator: ",").compactMap { Int($0) } ?? []
        return parts.count >= 4 && parts[0] == 0 && parts[3] == 0 && parts[1] != 0 && parts[2] != 0
    }

    /// The QuickTime creation date (ISO 8601, with or without a colon in the offset), else the file creation date.
    private static func captureDate(_ inventory: MetadataInventory) -> Date? {
        for key in ["qt.com.apple.quicktime.creationdate", "fs.creationDate"] {
            if let value = inventory[key]?.value, let date = parseDate(value) { return date }
        }
        return nil
    }

    private static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

extension CGSize {
    fileprivate var swapped: CGSize { CGSize(width: height, height: width) }
}
