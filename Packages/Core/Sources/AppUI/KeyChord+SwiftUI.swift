import SwiftUI

extension KeyChord {
    /// The SwiftUI shortcut for a chord of the command model.
    public var keyboardShortcut: KeyboardShortcut {
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        switch key {
        case .character(let character): return KeyboardShortcut(KeyEquivalent(character), modifiers: flags)
        case .return: return KeyboardShortcut(.return, modifiers: flags)
        case .delete: return KeyboardShortcut(.delete, modifiers: flags)
        }
    }
}
