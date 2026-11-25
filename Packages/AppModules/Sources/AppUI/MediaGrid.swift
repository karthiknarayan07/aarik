import AppKit
import SwiftUI

/// A titled run of grid items, for example one month.
public struct MediaSection<Item: Identifiable>: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let items: [Item]

    public init(id: String, title: String, subtitle: String, items: [Item]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }
}

/// An adaptive, sectioned grid with Finder-like selection: click, ⌘-click, ⇧-click, arrow keys, and Space.
public struct MediaGrid<Item: Identifiable, Tile: View>: View {
    public static var minimumTileWidth: CGFloat { 150 }
    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    let sections: [MediaSection<Item>]
    @Binding var selection: Set<Item.ID>
    let onSpace: () -> Void
    let tile: (Item, Bool) -> Tile

    @State private var state = GridSelection<Item.ID>()
    @State private var width: CGFloat = 0
    @FocusState private var isFocused: Bool

    public init(
        sections: [MediaSection<Item>], selection: Binding<Set<Item.ID>>, onSpace: @escaping () -> Void,
        @ViewBuilder tile: @escaping (Item, Bool) -> Tile
    ) {
        self.sections = sections
        self._selection = selection
        self.onSpace = onSpace
        self.tile = tile
    }

    private var columns: Int {
        max(1, Int((width - 2 * padding + spacing) / (Self.minimumTileWidth + spacing)))
    }

    private var ids: [[Item.ID]] { sections.map { $0.items.map(\.id) } }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                    alignment: .leading, spacing: spacing, pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                cell(item)
                            }
                        } header: {
                            SectionHeader(title: section.title, subtitle: section.subtitle)
                        }
                    }
                }
                .padding(padding)
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = $0
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                move(direction)
                if let focus = state.focus { proxy.scrollTo(focus) }
            }
            // Edit ▸ Select All reaches the focused grid through the responder chain, so a focused text field keeps its own.
            .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll() }
            .onKeyPress(.space) {
                onSpace()
                return .handled
            }
        }
    }

    private func cell(_ item: Item) -> some View {
        let isSelected = selection.contains(item.id)
        return tile(item, isSelected)
            .id(item.id)
            .contentShape(.rect)
            .onTapGesture { click(item.id, modifiers: Self.currentModifiers) }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { click(item.id, modifiers: []) }
    }

    private static var currentModifiers: GridClickModifiers {
        // The event being dispatched carries the modifiers held at the click; the global NSEvent.modifierFlags
        // can already be stale or empty by the time SwiftUI runs the tap action.
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        var modifiers: GridClickModifiers = []
        if flags.contains(.command) { modifiers.insert(.toggle) }
        if flags.contains(.shift) { modifiers.insert(.extend) }
        return modifiers
    }

    private func click(_ id: Item.ID, modifiers: GridClickModifiers) {
        isFocused = true
        state.selected = selection
        state.click(id, modifiers: modifiers, sections: ids)
        selection = state.selected
    }

    private func selectAll() {
        state.selected = selection
        state.selectAll(sections: ids)
        selection = state.selected
    }

    private func move(_ direction: MoveCommandDirection) {
        let mapped: GridDirection
        switch direction {
        case .left: mapped = .left
        case .right: mapped = .right
        case .up: mapped = .up
        case .down: mapped = .down
        @unknown default: return
        }
        state.selected = selection
        if let focus = state.focus, !selection.contains(focus) { state.focus = selection.first }
        state.move(mapped, sections: ids, columns: columns)
        selection = state.selected
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.headline)
                Text(verbatim: "·").foregroundStyle(.secondary)
            }
            Text(subtitle).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
        .background(.background)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
