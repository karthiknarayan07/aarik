import Foundation

/// A key equivalent, independent of SwiftUI so the menu's shortcuts can be tested for clashes.
public struct KeyChord: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public enum Key: Hashable, Sendable {
        case character(Character)
        case `return`
        case delete
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// ⌘ plus a character key.
    public static func command(_ character: Character) -> KeyChord {
        KeyChord(.character(character), .command)
    }
}

/// ⌘⏎ belongs to Add to Queue alone: no toolbar button or other control may bind it.
///
/// The commands the app's own menus add (File, Edit and Queue).
public enum AppCommandID: String, CaseIterable, Sendable {
    case addVideos
    case removeFromLibrary
    case addToQueue
    case pauseOrResumeQueue
    case retryAllFailed
}

/// What the commands need to know about the window to decide their titles and whether they are enabled.
public struct AppCommandContext: Equatable, Sendable {
    public var canRemoveFromLibrary: Bool
    public var canAddToQueue: Bool
    public var isQueuePaused: Bool
    public var failedJobCount: Int

    public init(
        canRemoveFromLibrary: Bool = false, canAddToQueue: Bool = false, isQueuePaused: Bool = false,
        failedJobCount: Int = 0
    ) {
        self.canRemoveFromLibrary = canRemoveFromLibrary
        self.canAddToQueue = canAddToQueue
        self.isQueuePaused = isQueuePaused
        self.failedJobCount = failedJobCount
    }
}

/// One menu item: its title (Title Case, with an ellipsis when it asks for more input), shortcut and state.
public struct AppCommand: Equatable, Sendable, Identifiable {
    public let id: AppCommandID
    public let title: String
    public let shortcut: KeyChord?
    public let isEnabled: Bool
}

/// The command list as a pure model. The menus in `MainApp` are built from it, so titles, shortcuts and enabled
/// states are tested here instead of through the UI.
public enum AppCommands {
    public static func command(_ id: AppCommandID, in context: AppCommandContext) -> AppCommand {
        switch id {
        case .addVideos:
            AppCommand(id: id, title: "Add Videos…", shortcut: .command("o"), isEnabled: true)
        case .removeFromLibrary:
            // No key equivalent: ⌘⌫ would take "delete to start of line" from the search field. Plain ⌫ in the grid
            // does the same.
            AppCommand(id: id, title: "Remove from Library", shortcut: nil, isEnabled: context.canRemoveFromLibrary)
        case .addToQueue:
            AppCommand(
                id: id, title: "Add to Queue", shortcut: KeyChord(.return, .command), isEnabled: context.canAddToQueue)
        case .pauseOrResumeQueue:
            // Not ⌘.: that is the system's Cancel. ⌥⌘P, a playback-style command as in Music.
            AppCommand(
                id: id, title: context.isQueuePaused ? "Resume Queue" : "Pause Queue",
                shortcut: KeyChord(.character("p"), [.command, .option]), isEnabled: true)
        case .retryAllFailed:
            AppCommand(id: id, title: "Retry All Failed", shortcut: nil, isEnabled: context.failedJobCount > 0)
        }
    }

    public static func all(in context: AppCommandContext) -> [AppCommand] {
        AppCommandID.allCases.map { command($0, in: context) }
    }

    /// Shortcuts owned by the system or by menu items the app adds elsewhere (View, Edit, the app menu, Window).
    /// No command of ours may take one of these.
    public static let reservedChords: [KeyChord] = [
        KeyChord(.character("s"), [.command, .control]),  // Hide or Show Sidebar
        KeyChord(.character("i"), [.command, .option]),  // Hide or Show Inspector
        KeyChord(.character("f"), [.command, .control]),  // Enter Full Screen
        .command(","),  // Settings
        .command("."),  // Cancel
        .command("q"), .command("w"), .command("h"), .command("m"),
        .command("c"), .command("v"), .command("x"), .command("a"), .command("z"), .command("f"),
    ]
}

/// ⌘1 to ⌘9 for the sections of the Go menu, in sidebar order; sections beyond the ninth have none.
public enum SectionShortcuts {
    private static let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    public static func chord(at index: Int) -> KeyChord? {
        digits.indices.contains(index) ? .command(digits[index]) : nil
    }
}
