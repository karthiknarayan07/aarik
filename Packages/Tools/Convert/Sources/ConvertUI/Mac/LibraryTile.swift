import Convert
import AppServices
import AppUI
import CoreGraphics
import LocalLibrary
import SwiftUI

/// A grid tile for a library item: loads its thumbnail and speaks as one element.
struct LibraryTile: View {
    let item: VideoItem
    let state: MediaTileState
    let thumbnails: ThumbnailSource
    /// A preset chosen in the inspector for this video alone, when it isn't the header's.
    var presetOverride: String?
    /// "−58%": what converting would save, from `LibraryInsight.savingsBadge`.
    var savingsBadge: String?
    @State private var image: CGImage?

    /// The poster to draw now: the one loaded for this tile, else one already in memory (a tile that scrolls back in
    /// has lost its state but not its poster, so it never flashes the placeholder).
    private var shownImage: CGImage? {
        image ?? (item.isAvailable ? thumbnails.cachedImage(for: item, maxPixel: Self.posterPixels) : nil)
    }

    /// The longer side asked of a poster: about 3x a phone's tile, 2x a Mac's.
    static let posterPixels = 480

    var body: some View {
        MediaTile(
            image: shownImage, badges: MediaBadge.ordered(item.badges).map(\.tileLabel),
            sizeLabel: ByteFormat.string(item.byteSize), isAvailable: item.isAvailable, state: state,
            note: presetOverride, savingsBadge: savingsBadge
        )
        // Keyed on the whole item: a re-read in place (same path, new file) or a move loads the new poster.
        .task(id: item) {
            guard item.isAvailable, shownImage == nil else { return }
            image = await thumbnails.image(for: item, maxPixel: Self.posterPixels)
        }
        .help(item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                ItemDescription.accessibilityLabel(for: item), presetOverride.map { "\($0) preset" },
                savingsBadge.map { "could save \($0.dropFirst())" },
            ]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// A tile redraws only when what it shows changed: the item, its selection state or its badges. (The thumbnail source
/// is one shared object for the app's life.)
extension LibraryTile: @MainActor Equatable {
    static func == (left: LibraryTile, right: LibraryTile) -> Bool {
        left.item == right.item && left.state == right.state && left.presetOverride == right.presetOverride
            && left.savingsBadge == right.savingsBadge
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

    /// "17 Aug 2026 · 12 MP · 4032×3024" for images, or "17 Aug 2026 · 3840×2160 · 30 fps · 0:42" for videos.
    static func details(_ item: VideoItem) -> String {
        if item.isImage {
            let mp =
                item.pixelSize.width > 0 && item.pixelSize.height > 0
                ? "\(item.megapixels.formatted(.number.precision(.fractionLength(0...1)))) MP" : nil
            return [date(item), mp, resolution(item)].compactMap { $0 }.joined(separator: " · ")
        }
        return [date(item), resolution(item), frameRate(item), duration(item)].compactMap { $0 }.joined(
            separator: " · ")
    }

    static func accessibilityLabel(for item: VideoItem) -> String {
        var parts = [item.name, ByteFormat.string(item.byteSize)]
        parts += MediaBadge.ordered(item.badges).map(\.displayName)
        parts += [date(item), duration(item)].compactMap { $0 }
        if !item.isAvailable { parts.append("missing") }
        return parts.joined(separator: ", ")
    }
}
