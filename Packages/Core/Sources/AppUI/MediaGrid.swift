import AppCore
#if os(macOS)
    import AppKit
#endif
import CoreTransferable
import Observation
import SwiftUI
import UniformTypeIdentifiers

private let mediaGridSpace = "media-grid"

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

/// What the grid asks the app to do with its selection.
public struct MediaGridActions<ID: Hashable> {
    /// Double-click and Return.
    public var open: (Set<ID>) -> Void
    /// Space.
    public var quickLook: () -> Void

    public init(open: @escaping (Set<ID>) -> Void, quickLook: @escaping () -> Void) {
        self.open = open
        self.quickLook = quickLook
    }
}

/// A video dragged out of the grid. The receiver is handed a copy of the file, never the original, so a drop in
/// Finder or an app can't move or change it.
struct MediaDragItem<ID: Hashable & Sendable>: Identifiable, Transferable {
    let id: ID
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { item in
            SentTransferredFile(item.url, allowAccessingOriginalFile: false)
        }
    }
}

/// An adaptive, sectioned grid that behaves like the grids in Finder and Photos:
/// - click, ⌘-click and ⇧-click; arrow keys (⇧ extends), Home and End; ⌘A
/// - marquee selection from empty space
/// - double-click and Return open; Space previews
/// - type-select: type a name to jump to it
/// - drag files out to Finder or other apps
/// - a ring on the keyboard-focused tile, and a grey selection when the window or the grid isn't active
public struct MediaGrid<Item: Identifiable, Tile: View>: View where Item.ID: Sendable {

    let sections: [MediaSection<Item>]
    @Binding var selection: Set<Item.ID>
    let name: (Item) -> String
    let dragFile: ((Item) -> URL?)?
    let actions: MediaGridActions<Item.ID>
    let tile: (Item, MediaTileState) -> Tile

    @State private var state = GridSelection<Item.ID>()
    @State private var viewport = CGSize.zero
    @State private var typeSelect = TypeSelectBuffer()
    @State private var frames = TileFrames<Item.ID>()
    @State private var headerFrames = TileFrames<String>()
    @State private var marquee = MarqueeState<Item.ID>()
    @FocusState private var isFocused: Bool
    #if os(macOS)
        @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var padding: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var minimumTileWidth: CGFloat = 150

    /// - Parameters:
    ///   - name: the text type-select matches against.
    ///   - dragFile: the file a tile drags out, or nil when it has none; the grid doesn't drag out when this is nil.
    public init(
        sections: [MediaSection<Item>], selection: Binding<Set<Item.ID>>, name: @escaping (Item) -> String,
        dragFile: ((Item) -> URL?)? = nil, actions: MediaGridActions<Item.ID>,
        @ViewBuilder tile: @escaping (Item, MediaTileState) -> Tile
    ) {
        self.sections = sections
        self._selection = selection
        self.name = name
        self.dragFile = dragFile
        self.actions = actions
        self.tile = tile
    }

    private var columns: Int {
        max(1, Int((viewport.width - 2 * padding + spacing) / (minimumTileWidth + spacing)))
    }

    private var ids: [[Item.ID]] { sections.map { $0.items.map(\.id) } }

    private var emphasis: SelectionEmphasis {
        #if os(macOS)
            .resolve(isWindowActive: controlActiveState != .inactive, isGridFocused: isFocused)
        #else
            .resolve(isWindowActive: true, isGridFocused: isFocused)
        #endif
    }

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
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .named(mediaGridSpace))
                                } action: { [headerFrames] in
                                    headerFrames.values[section.id] = $0
                                }
                                .onDisappear { [headerFrames] in headerFrames.values[section.id] = nil }
                        }
                    }
                }
                .modifier(
                    DragOutContainer(isEnabled: dragFile != nil, selection: selection, payload: dragItems(for:))
                )
                .padding(padding)
                // Empty space below the last row still belongs to the grid: a click there clears the selection.
                .frame(minHeight: viewport.height, alignment: .top)
                .coordinateSpace(.named(mediaGridSpace))
                #if os(macOS)
                    .simultaneousGesture(marqueeGesture)
                    .overlay(alignment: .topLeading) { MarqueeOverlay(state: marquee) }
                #else
                    .contentShape(.rect)
                    .onTapGesture {
                        isFocused = true
                        state.selected = []
                        selection = []
                    }
                #endif
            }
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                viewport = $0
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handle(press, scrollTo: { proxy.scrollTo($0) })
            }
            // Edit ▸ Select All reaches the focused grid through the responder chain, so a focused text field keeps its own.
            #if os(macOS)
                .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll() }
            #endif
        }
    }

    private func cell(_ item: Item) -> some View {
        let id = item.id
        let isSelected = selection.contains(id)
        let tileState = MediaTileState(
            isSelected: isSelected, isFocused: isFocused && state.focus == id, isEmphasized: emphasis == .emphasized)
        return tile(item, tileState)
            .id(id)
            .contentShape(.rect)
            .onTapGesture { click(id) }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(mediaGridSpace))
            } action: { [frames] in
                frames.values[id] = $0
            }
            .onDisappear { [frames] in frames.values[id] = nil }
            .modifier(DragOutItem(isEnabled: dragFile != nil, id: id))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { click(id, count: 1, modifiers: []) }
            .accessibilityAction(named: "Open") { actions.open([id]) }
    }

    // MARK: Mouse

    private func click(_ id: Item.ID) {
        #if os(macOS)
            let event = NSApp.currentEvent
            click(id, count: event?.clickCount ?? 1, modifiers: Self.clickModifiers(event?.modifierFlags ?? []))
        #else
            // Touch has no modifier keys, so tapping a tile toggles it in the selection.
            click(id, count: 1, modifiers: .toggle)
        #endif
    }

    private func click(_ id: Item.ID, count: Int, modifiers: GridClickModifiers) {
        isFocused = true
        typeSelect.reset()
        switch GridClickIntent.resolve(clickCount: count, modifiers: modifiers) {
        case .select(let modifiers):
            state.selected = selection
            state.click(id, modifiers: modifiers, sections: ids)
            selection = state.selected
        case .open:
            if !selection.contains(id) {
                state.select(id)
                selection = state.selected
            }
            actions.open(selection)
        }
    }

    /// The event being dispatched carries the modifiers held at the click; the global NSEvent.modifierFlags
    /// can already be stale or empty by the time SwiftUI runs the tap action.
    #if os(macOS)
        private static func clickModifiers(_ flags: NSEvent.ModifierFlags) -> GridClickModifiers {
            var modifiers: GridClickModifiers = []
            if flags.contains(.command) { modifiers.insert(.toggle) }
            if flags.contains(.shift) { modifiers.insert(.extend) }
            return modifiers
        }
    #endif

    /// Rubber-band selection from empty space; a click on empty space clears the selection.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(mediaGridSpace))
            .onChanged { value in
                if marquee.start != value.startLocation {
                    marquee.begin(
                        at: value.startLocation, base: selection,
                        mode: Self.currentMarqueeMode(),
                        startsOnEmptySpace: MarqueeSelection.startsOnEmptySpace(
                            value.startLocation, frames: frames.values, excluding: headerFrames.values.values))
                }
                guard marquee.startsOnEmptySpace,
                    MarqueeSelection.isDrag(from: value.startLocation, to: value.location) || marquee.rect != nil
                else { return }
                isFocused = true
                let rect = MarqueeSelection.rect(from: value.startLocation, to: value.location)
                marquee.rect = rect
                let reached = MarqueeSelection.selection(
                    rect: rect, frames: frames.values, base: marquee.base, mode: marquee.mode)
                if reached != selection {
                    selection = reached
                    state.selected = reached
                }
            }
            .onEnded { value in
                defer { marquee.end() }
                guard marquee.startsOnEmptySpace, marquee.rect == nil, marquee.mode == .replace else { return }
                _ = value
                // A plain click on empty space.
                isFocused = true
                state.selected = []
                selection = []
            }
    }

    /// Command toggles and Shift adds on the Mac; a touch drag always replaces.
    private static func currentMarqueeMode() -> MarqueeSelection.Mode {
        #if os(macOS)
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) { return .toggle }
            if flags.contains(.shift) { return .add }
        #endif
        return .replace
    }

    // MARK: Keyboard

    private func handle(_ press: KeyPress, scrollTo: (Item.ID) -> Void) -> KeyPress.Result {
        guard let key = Self.gridKey(press) else { return .ignored }
        let now = Date.now
        guard
            let command = GridKeyCommand.resolve(
                key, modifiers: Self.keyModifiers(press.modifiers), isTypeSelecting: typeSelect.isTyping(at: now))
        else { return .ignored }
        state.selected = selection
        if let focus = state.focus, !selection.contains(focus) { state.focus = selection.first }
        switch command {
        case .move(let direction, let extend):
            typeSelect.reset()
            if extend {
                state.extend(direction, sections: ids, columns: columns)
            } else {
                state.move(direction, sections: ids, columns: columns)
            }
        case .jump(let toEnd, let extend):
            typeSelect.reset()
            state.jump(toEnd: toEnd, extend: extend, sections: ids)
        case .open:
            guard !selection.isEmpty else { return .handled }
            actions.open(selection)
            return .handled
        case .quickLook:
            actions.quickLook()
            return .handled
        case .typeSelect(let typed):
            let word = typeSelect.append(typed, at: now)
            let names = sections.flatMap(\.items).map { (id: $0.id, name: name($0)) }
            guard let match = TypeSelectBuffer.match(prefix: word, in: names) else { return .handled }
            state.select(match)
        }
        selection = state.selected
        if let focus = state.focus { scrollTo(focus) }
        return .handled
    }

    private static func gridKey(_ press: KeyPress) -> GridKey? {
        switch press.key {
        case .leftArrow: .arrow(.left)
        case .rightArrow: .arrow(.right)
        case .upArrow: .arrow(.up)
        case .downArrow: .arrow(.down)
        case .home: .home
        case .end: .end
        case .return: .returnKey
        case .space: .space
        default: press.characters.isEmpty ? nil : .character(press.characters)
        }
    }

    private static func keyModifiers(_ modifiers: EventModifiers) -> GridKeyModifiers {
        var result: GridKeyModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    private func selectAll() {
        state.selected = selection
        state.selectAll(sections: ids)
        selection = state.selected
    }

    // MARK: Drag out

    private func dragItems(for dragged: [Item.ID]) -> [MediaDragItem<Item.ID>] {
        guard let dragFile else { return [] }
        let items = Dictionary(sections.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return MediaDragPayload.entries(
            ids: dragged, gridOrder: ids.flatMap { $0 }, url: { items[$0].flatMap(dragFile) }
        ).map { MediaDragItem(id: $0.id, url: $0.url) }
    }
}

// MARK: - Drag modifiers

private struct DragOutContainer<ID: Hashable & Sendable>: ViewModifier {
    let isEnabled: Bool
    let selection: Set<ID>
    let payload: ([ID]) -> [MediaDragItem<ID>]

    func body(content: Content) -> some View {
        #if os(macOS)
            macBody(content)
        #else
            // The multi-item drag container is iOS 27 API; iOS drags out through `DragOut.itemProvider`.
            content
        #endif
    }

    #if os(macOS)
        @ViewBuilder private func macBody(_ content: Content) -> some View {
            if isEnabled {
                content
                    .dragContainer(for: MediaDragItem<ID>.self) { (dragged: [ID]) in payload(dragged) }
                    .dragContainerSelection(Array(selection))
                    // While a tile is being dragged, the window's own drop must not import it (`ImportDropGuard`).
                    .onDragSessionUpdated { session in
                        if session.phase == .initial || session.phase == .active {
                            InternalDrag.isActive = true
                        } else if session.phase == .dataTransferCompleted {
                            InternalDrag.isActive = false
                        } else if case .ended = session.phase {
                            InternalDrag.isActive = false
                        }
                    }
            } else {
                content
            }
        }
    #endif
}

private struct DragOutItem<ID: Hashable & Sendable>: ViewModifier {
    let isEnabled: Bool
    let id: ID

    func body(content: Content) -> some View {
        #if os(macOS)
            if isEnabled {
                content.draggable(containerItemID: id)
            } else {
                content
            }
        #else
            content
        #endif
    }
}

// MARK: - Marquee state

/// Where each realized tile is, in the grid's coordinate space. Kept out of SwiftUI's state so a scroll doesn't redraw.
@MainActor
private final class TileFrames<ID: Hashable> {
    var values: [ID: CGRect] = [:]
}

@MainActor
@Observable
private final class MarqueeState<ID: Hashable> {
    /// The rectangle being drawn; nil until the drag moves far enough.
    var rect: CGRect?
    @ObservationIgnored var start: CGPoint?
    @ObservationIgnored var base: Set<ID> = []
    @ObservationIgnored var mode = MarqueeSelection.Mode.replace
    @ObservationIgnored var startsOnEmptySpace = false

    func begin(at point: CGPoint, base: Set<ID>, mode: MarqueeSelection.Mode, startsOnEmptySpace: Bool) {
        start = point
        self.base = base
        self.mode = mode
        self.startsOnEmptySpace = startsOnEmptySpace
        rect = nil
    }

    func end() {
        start = nil
        rect = nil
        startsOnEmptySpace = false
    }
}

private struct MarqueeOverlay<ID: Hashable>: View {
    let state: MarqueeState<ID>

    private static var selectionColor: Color {
        #if os(macOS)
            Color(nsColor: .selectedContentBackgroundColor)
        #else
            Color.accentColor
        #endif
    }

    var body: some View {
        if let rect = state.rect {
            Rectangle()
                .fill(Self.selectionColor.opacity(0.18))
                .overlay { Rectangle().strokeBorder(Self.selectionColor, lineWidth: 1) }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
        // A translucent header, like Photos' date headers: tiles scroll under it and the toolbar's edge effect shows.
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
