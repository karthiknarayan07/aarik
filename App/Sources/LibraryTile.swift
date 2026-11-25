import AppUI
import CoreGraphics
import LocalLibrary
import SwiftUI

/// A grid tile for a library item: loads its thumbnail and speaks as one element.
struct LibraryTile: View {
    let item: VideoItem
    let isSelected: Bool
    let thumbnails: ThumbnailCache
    /// A preset chosen in the inspector for this video alone, when it isn't the header's.
    var presetOverride: String?
    @State private var image: CGImage?

    var body: some View {
        MediaTile(
            image: image, badges: MediaBadge.ordered(item.badges).map(\.tileLabel),
            sizeLabel: ByteFormat.string(item.byteSize), isAvailable: item.isAvailable, isSelected: isSelected,
            note: presetOverride
        )
        .task(id: item.url) {
            guard item.isAvailable else { return }
            image = await thumbnails.thumbnail(for: item.url, maxPixel: 320)
        }
        .help(item.url.lastPathComponent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [ItemDescription.accessibilityLabel(for: item), presetOverride.map { "\($0) preset" }]
                .compactMap { $0 }.joined(separator: ", "))
    }
}

/// How an item is described in text.
enum ItemDescription {
    static func date(_ item: VideoItem) -> String? {
        item.captureDate?.formatted(date: .abbreviated, time: .omitted)
    }

    static func resolution(_ item: VideoItem) -> String? {
        let width = Int(item.pixelSize.width)
        let height = Int(item.pixelSize.height)
        return width > 0 && height > 0 ? "\(width)×\(height)" : nil
    }

    static func frameRate(_ item: VideoItem) -> String? {
        item.frameRate > 0 ? "\(Int(item.frameRate.rounded())) fps" : nil
    }

    static func duration(_ item: VideoItem) -> String? {
        guard item.duration > 0 else { return nil }
        let pattern: Duration.TimeFormatStyle.Pattern = item.duration >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(item.duration.rounded()).formatted(.time(pattern: pattern))
    }

    /// "17 Aug 2026 · 3840×2160 · 30 fps · 0:42"
    static func details(_ item: VideoItem) -> String {
        [date(item), resolution(item), frameRate(item), duration(item)].compactMap { $0 }.joined(separator: " · ")
    }

    static func accessibilityLabel(for item: VideoItem) -> String {
        var parts = [item.url.lastPathComponent, ByteFormat.string(item.byteSize)]
        parts += MediaBadge.ordered(item.badges).map(\.displayName)
        parts += [date(item), duration(item)].compactMap { $0 }
        if !item.isAvailable { parts.append("missing") }
        return parts.joined(separator: ", ")
    }
}
