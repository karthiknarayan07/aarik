import Foundation

/// A key the grid listens for, without SwiftUI's types so the rules are testable.
enum GridKey: Equatable {
    case arrow(GridDirection)
    case home
    case end
    case returnKey
    case space
    /// Anything else that typed text.
    case character(String)
}

struct GridKeyModifiers: OptionSet {
    let rawValue: Int
    static let shift = GridKeyModifiers(rawValue: 1)
    static let command = GridKeyModifiers(rawValue: 2)
    static let option = GridKeyModifiers(rawValue: 4)
    static let control = GridKeyModifiers(rawValue: 8)
}

/// What a key does in the grid.
enum GridKeyCommand: Equatable {
    case move(GridDirection, extend: Bool)
    case jump(toEnd: Bool, extend: Bool)
    /// Return, like double-click: open the selection.
    case open
    /// Space: Quick Look.
    case quickLook
    case typeSelect(String)

    /// Finder's rules: arrows move and ⇧ extends; Home and End jump; Return opens; Space previews, unless a word
    /// is being typed, when it is part of the word. ⌘ and ⌃ combinations belong to the menus (⌘⏎ adds to the queue),
    /// so they aren't handled here.
    static func resolve(_ key: GridKey, modifiers: GridKeyModifiers, isTypeSelecting: Bool) -> GridKeyCommand? {
        let extend = modifiers.contains(.shift)
        let reserved = modifiers.contains(.command) || modifiers.contains(.control)
        switch key {
        case .arrow(let direction):
            return reserved || modifiers.contains(.option) ? nil : .move(direction, extend: extend)
        case .home:
            return reserved ? nil : .jump(toEnd: false, extend: extend)
        case .end:
            return reserved ? nil : .jump(toEnd: true, extend: extend)
        case .returnKey:
            return modifiers.isEmpty ? .open : nil
        case .space:
            if isTypeSelecting { return modifiers.isEmpty ? .typeSelect(" ") : nil }
            return modifiers.isEmpty ? .quickLook : nil
        case .character(let text):
            guard !reserved, isTypable(text) else { return nil }
            return .typeSelect(text)
        }
    }

    private static func isTypable(_ text: String) -> Bool {
        !text.isEmpty
            && text.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                    && !CharacterSet.illegalCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
    }
}

/// Type-select: typing a few letters jumps to the item whose name starts with them. The word resets after a pause.
struct TypeSelectBuffer {
    static let timeout: TimeInterval = 1

    private(set) var text = ""
    private var lastInput: Date?

    var isActive: Bool { !text.isEmpty }

    /// Adds typed text, starting a new word when the last key was more than `timeout` ago.
    mutating func append(_ typed: String, at date: Date) -> String {
        if let lastInput, date.timeIntervalSince(lastInput) > Self.timeout { text = "" }
        text += typed
        lastInput = date
        return text
    }

    /// Whether a word is still being typed at `date`: Space joins it rather than previewing.
    func isTyping(at date: Date) -> Bool {
        guard let lastInput, isActive else { return false }
        return date.timeIntervalSince(lastInput) <= Self.timeout
    }

    mutating func reset() {
        text = ""
        lastInput = nil
    }

    /// The first item, in grid order, whose name starts with `prefix`, ignoring case and accents.
    static func match<ID>(prefix: String, in names: [(id: ID, name: String)]) -> ID? {
        guard !prefix.isEmpty else { return nil }
        return names.first {
            $0.name.range(
                of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }?.id
    }
}
