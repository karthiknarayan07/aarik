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
    let state: MediaTileState
    let note: String?

    @ScaledMetric(relativeTo: .body) private var inset: CGFloat = 4
    @ScaledMetric(relativeTo: .body) private var focusWidth: CGFloat = 2

    public init(
        image: CGImage?, badges: [String], sizeLabel: String, isAvailable: Bool, state: MediaTileState,
        note: String? = nil
    ) {
        self.image = image
        self.badges = badges
        self.sizeLabel = sizeLabel
        self.isAvailable = isAvailable
        self.state = state
        self.note = note
    }

    public var body: some View {
        Rectangle()
            .fill(.quaternary)
            // Opaque underneath, so the selection colour doesn't tint a poster that hasn't loaded.
            .background(.background)
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
            .background {
                // Finder's and Photos' selection: the system's selection colour around the poster, grey when the
                // window is in the background or the grid doesn't have focus.
                if state.isSelected {
                    RoundedRectangle(cornerRadius: Self.cornerRadius + inset)
                        .fill(selectionColor)
                        .padding(-inset)
                }
            }
            .overlay {
                if state.isFocused && !state.isSelected {
                    RoundedRectangle(cornerRadius: Self.cornerRadius + inset)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: focusWidth)
                        .padding(-inset)
                }
            }
    }

    private var selectionColor: Color {
        Color(
            nsColor: state.isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
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

/// A small caption on a dark plate, readable over any thumbnail in light and dark appearance. The plate is darker
/// with Increase Contrast.
private struct TileLabel: View {
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.black.opacity(contrast == .increased ? 0.8 : 0.55), in: .rect(cornerRadius: 4))
    }
}
