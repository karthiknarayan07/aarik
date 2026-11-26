import CoreGraphics
import Foundation

/// Rubber-band selection: which tiles a dragged rectangle reaches. Frames are in the grid's own coordinate space.
enum MarqueeSelection {
    /// How the rectangle combines with the selection the drag started from.
    enum Mode: Equatable {
        case replace
        /// ⇧: add what the rectangle reaches.
        case add
        /// ⌘: flip what the rectangle reaches.
        case toggle
    }

    /// The least distance a drag moves before it is a marquee and not a click.
    static let threshold: CGFloat = 4

    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// A marquee starts only on empty space; a drag that starts on a tile belongs to the tile (drag-out).
    static func startsOnEmptySpace<ID>(_ point: CGPoint, frames: [ID: CGRect]) -> Bool {
        !frames.values.contains { $0.contains(point) }
    }

    static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= threshold
    }

    static func selection<ID: Hashable>(rect: CGRect, frames: [ID: CGRect], base: Set<ID>, mode: Mode) -> Set<ID> {
        let reached = Set(frames.filter { $0.value.intersects(rect) }.keys)
        switch mode {
        case .replace: return reached
        case .add: return base.union(reached)
        case .toggle: return base.symmetricDifference(reached)
        }
    }
}

/// Whether the selection draws in the accent colour or in grey: Finder and Photos show grey when the window is in
/// the background or the grid doesn't have keyboard focus.
enum SelectionEmphasis: Equatable, Sendable {
    case emphasized
    case unemphasized

    static func resolve(isWindowActive: Bool, isGridFocused: Bool) -> SelectionEmphasis {
        isWindowActive && isGridFocused ? .emphasized : .unemphasized
    }
}

/// What a tile needs to draw its selection and keyboard focus.
public struct MediaTileState: Equatable, Sendable {
    public var isSelected: Bool
    /// The keyboard-focused tile while the grid has focus: it gets a focus ring when it isn't selected.
    public var isFocused: Bool
    public var isEmphasized: Bool

    public init(isSelected: Bool = false, isFocused: Bool = false, isEmphasized: Bool = true) {
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.isEmphasized = isEmphasized
    }
}

/// What a drag out of the grid carries: the tiles the system says are dragged (the selection when the dragged tile is
/// part of it, else that tile), in the grid's order. `url` is nil for a tile that has no file to give (missing, or a Photos video), and that tile is left out.
public enum MediaDragPayload {
    public static func entries<ID: Hashable>(
        ids: [ID], gridOrder: [ID], url: (ID) -> URL?
    ) -> [(id: ID, url: URL)] {
        let wanted = Set(ids)
        return gridOrder.compactMap { id in
            guard wanted.contains(id), let url = url(id) else { return nil }
            return (id, url)
        }
    }
}

/// How many videos Open and Return start at once. More than this is almost always a slip, and every one would open a
/// player window.
public enum OpenLimit {
    public static let maximum = 12

    public static func allows(_ count: Int) -> Bool { count <= maximum }
}
