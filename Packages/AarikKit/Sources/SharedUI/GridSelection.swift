/// The modifier keys a grid click cares about.
struct GridClickModifiers: OptionSet {
    let rawValue: Int
    /// ⌘-click: add or remove one item.
    static let toggle = GridClickModifiers(rawValue: 1)
    /// ⇧-click: select the range from the anchor.
    static let extend = GridClickModifiers(rawValue: 2)
}

/// What a click on a tile means: a double-click with no modifier opens, as in Finder and Photos; anything else selects.
enum GridClickIntent: Equatable {
    case select(GridClickModifiers)
    case open

    static func resolve(clickCount: Int, modifiers: GridClickModifiers) -> GridClickIntent {
        clickCount >= 2 && modifiers.isEmpty ? .open : .select(modifiers)
    }
}

enum GridDirection { case left, right, up, down }

/// Which grid items are selected, with Finder-like click and arrow-key rules.
struct GridSelection<ID: Hashable> {
    var selected: Set<ID> = []
    /// The item the last click or arrow landed on.
    var focus: ID?
    /// Where a ⇧-click range starts.
    var anchor: ID?

    init(selected: Set<ID> = []) {
        self.selected = selected
    }

    mutating func click(_ id: ID, modifiers: GridClickModifiers, sections: [[ID]]) {
        if modifiers.contains(.extend), let anchor, let range = Self.range(from: anchor, to: id, in: sections) {
            selected = Set(range)
        } else if modifiers.contains(.toggle) {
            if selected.remove(id) == nil { selected.insert(id) }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
        focus = id
    }

    /// Selects every item in every section; the first item becomes the anchor and focus when there is none.
    mutating func selectAll(sections: [[ID]]) {
        let flat = sections.flatMap { $0 }
        guard let first = flat.first else { return }
        selected = Set(flat)
        if focus == nil { focus = first }
        if anchor == nil { anchor = first }
    }

    /// Selects one item and makes it the focus and anchor (type-select, and arrows without ⇧).
    mutating func select(_ id: ID) {
        selected = [id]
        focus = id
        anchor = id
    }

    /// Moves a single selection one tile. Up and down keep the column, crossing into the next or previous section.
    mutating func move(_ direction: GridDirection, sections: [[ID]], columns: Int) {
        let sections = sections.filter { !$0.isEmpty }
        guard let first = sections.first?.first else { return }
        guard let current = focus ?? selected.first,
            let target = Self.target(direction, from: current, sections, columns)
        else {
            select(first)
            return
        }
        select(target)
    }

    /// ⇧-arrow: moves the focus and selects the range from the anchor to it.
    mutating func extend(_ direction: GridDirection, sections: [[ID]], columns: Int) {
        let sections = sections.filter { !$0.isEmpty }
        guard let first = sections.first?.first else { return }
        guard let current = focus ?? selected.first,
            let target = Self.target(direction, from: current, sections, columns)
        else {
            select(first)
            return
        }
        extend(to: target, current: current, sections: sections)
    }

    /// Home and End: the first or last item. With ⇧ the range from the anchor reaches it.
    mutating func jump(toEnd: Bool, extend shouldExtend: Bool, sections: [[ID]]) {
        let flat = sections.flatMap { $0 }
        guard let target = toEnd ? flat.last : flat.first else { return }
        if shouldExtend, let current = focus ?? selected.first {
            extend(to: target, current: current, sections: sections)
        } else {
            select(target)
        }
    }

    private mutating func extend(to target: ID, current: ID, sections: [[ID]]) {
        let origin = anchor ?? current
        anchor = origin
        focus = target
        if let range = Self.range(from: origin, to: target, in: sections) { selected = Set(range) }
    }

    /// The item an arrow key reaches from `current`; `current` itself at an edge, nil when it isn't in the grid.
    static func target(_ direction: GridDirection, from current: ID, _ sections: [[ID]], _ columns: Int) -> ID? {
        let sections = sections.filter { !$0.isEmpty }
        guard let (section, index) = position(of: current, in: sections) else { return nil }
        let columns = max(1, columns)
        let items = sections[section]
        switch direction {
        case .left:
            if index > 0 { return items[index - 1] }
            if section > 0, let last = sections[section - 1].last { return last }
        case .right:
            if index + 1 < items.count { return items[index + 1] }
            if section + 1 < sections.count { return sections[section + 1][0] }
        case .down:
            let rowStart = (index / columns + 1) * columns
            if rowStart < items.count {
                return items[min(index + columns, items.count - 1)]
            } else if section + 1 < sections.count {
                let next = sections[section + 1]
                return next[min(index % columns, next.count - 1)]
            }
        case .up:
            if index >= columns {
                return items[index - columns]
            } else if section > 0 {
                let previous = sections[section - 1]
                let lastRowStart = (previous.count - 1) / columns * columns
                return previous[min(lastRowStart + index % columns, previous.count - 1)]
            }
        }
        return current
    }

    private static func position(of id: ID, in sections: [[ID]]) -> (Int, Int)? {
        for (section, items) in sections.enumerated() {
            if let index = items.firstIndex(of: id) { return (section, index) }
        }
        return nil
    }

    private static func range(from start: ID, to end: ID, in sections: [[ID]]) -> ArraySlice<ID>? {
        let flat = sections.flatMap { $0 }
        guard let lower = flat.firstIndex(of: start), let upper = flat.firstIndex(of: end) else { return nil }
        return flat[min(lower, upper)...max(lower, upper)]
    }
}

/// What a grid tile's context menu acts on (Finder-like): the selection when the clicked tile is part of it, else
/// that tile alone.
public enum ContextMenuTargets {
    public static func ids<ID: Hashable>(clicked: ID, selection: Set<ID>) -> Set<ID> {
        selection.contains(clicked) ? selection : [clicked]
    }
}
