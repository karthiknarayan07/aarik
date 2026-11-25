import CoreGraphics
import SwiftUI

/// One grid tile: a poster frame, up to three badges, the file size, and an optional note (such as a preset chosen
/// for this video alone).
public struct MediaTile: View {
    public static let cornerRadius: CGFloat = 6
    public static let maxBadges = 3

    let image: CGImage?
    let badges: [String]
    let sizeLabel: String
    let isAvailable: Bool
    let isSelected: Bool
    let note: String?

    public init(
        image: CGImage?, badges: [String], sizeLabel: String, isAvailable: Bool, isSelected: Bool, note: String? = nil
    ) {
        self.image = image
        self.badges = badges
        self.sizeLabel = sizeLabel
        self.isAvailable = isAvailable
        self.isSelected = isSelected
        self.note = note
    }

    public var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay { poster }
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .opacity(isAvailable ? 1 : 0.4)
            .overlay(alignment: .topLeading) { badgeRow }
            .overlay(alignment: .bottomTrailing) { TileLabel(sizeLabel).padding(5) }
            .overlay(alignment: .bottomLeading) {
                if let note { TileLabel(note).padding(5) }
            }
            .overlay(alignment: .topTrailing) { missingBadge }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Self.cornerRadius + 3)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(-4)
                }
            }
    }

    @ViewBuilder private var poster: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "film")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 3) {
            ForEach(badges.prefix(Self.maxBadges), id: \.self) { badge in
                TileLabel(badge).fontWeight(.semibold)
            }
        }
        .padding(5)
    }

    @ViewBuilder private var missingBadge: some View {
        if !isAvailable {
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .padding(5)
                .help("The file is missing or its drive isn't connected")
        }
    }
}

/// A small caption on a dark material, readable over any thumbnail.
private struct TileLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.thinMaterial, in: .rect(cornerRadius: 4))
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.primary)
    }
}
