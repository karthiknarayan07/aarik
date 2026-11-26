import SwiftUI

/// One row of a tool's sidebar. The shell draws the rows; the tool says what they are.
public struct ToolSidebarItem<Destination: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public enum Availability: Hashable, Sendable {
        case available
        /// Shown disabled and not selectable.
        case comingSoon
    }

    public let id: String
    /// Nil for a row that can't be selected.
    public let destination: Destination?
    public let title: String
    public let systemImage: String
    /// A badge number; nil shows none.
    public let count: Int?
    /// A running job's progress, from 0 to 1; shows a small ring.
    public let progress: Double?
    public let availability: Availability

    public init(
        id: String, destination: Destination?, title: String, systemImage: String, count: Int? = nil,
        progress: Double? = nil, availability: Availability = .available
    ) {
        self.id = id
        self.destination = destination
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.progress = progress
        self.availability = availability
    }

    /// What VoiceOver reads for the row: its title.
    public var accessibilityLabel: String { title }

    /// What VoiceOver reads after the title: the count and the running progress, or that the tool is coming soon.
    public var accessibilityValue: String {
        if availability == .comingSoon { return "coming soon" }
        var parts: [String] = []
        if let count { parts.append("\(count)") }
        if let progress { parts.append("converting \(Int((progress * 100).rounded()))%") }
        return parts.joined(separator: ", ")
    }
}

/// A titled group of sidebar rows.
public struct ToolSidebarSection<Destination: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public let title: String
    public let items: [ToolSidebarItem<Destination>]
    public var id: String { title }

    public init(title: String, items: [ToolSidebarItem<Destination>]) {
        self.title = title
        self.items = items
    }
}

/// What the shell draws for a sidebar: one row per item, and which rows can be selected. The shell asks this type, so
/// the decisions are testable without a window.
public struct ToolSidebarModel<Destination: Hashable & Sendable>: Equatable {
    public struct Row: Identifiable, Equatable {
        public let item: ToolSidebarItem<Destination>
        public var id: String { item.id }
        /// The value the row selects; nil for a row that can't be selected.
        public var tag: Destination? { isSelectable ? item.destination : nil }
        public var isSelectable: Bool { item.availability == .available && item.destination != nil }
    }

    public struct Section: Identifiable, Equatable {
        public let title: String
        public let rows: [Row]
        public var id: String { title }
    }

    public let sections: [Section]

    public init(_ sections: [ToolSidebarSection<Destination>]) {
        self.sections = sections.map { section in
            Section(title: section.title, rows: section.items.map(Row.init(item:)))
        }
    }

    /// Every page the sidebar can select, in order.
    public var selectableDestinations: [Destination] {
        sections.flatMap(\.rows).compactMap(\.tag)
    }

    /// Whether a click may change the selection to this: a listed, enabled row, or nothing.
    public func accepts(_ destination: Destination?) -> Bool {
        destination.map(selectableDestinations.contains) ?? true
    }
}

/// No menu commands.
public struct NoToolCommands: Commands {
    public init() {}
    public var body: some Commands { CommandGroup(after: .help) {} }
}

/// What a tool gives the shell: its sidebar, its screens, its toolbar and its inspector. The shell hosts one module
/// and knows nothing else of the tool: the module also supplies the dialogs, file drops and sheets that belong to it.
/// The shared services (queue, settings, updater, notifier) belong to the app and are passed to the module when it is
/// made; the module doesn't own them. Nothing here depends on AppKit, so the same shell can host a module on iOS.
///
/// This is a boundary, not a plugin system: there is no loading and no registry (ADR 0004).
@MainActor
public protocol ToolModule: AnyObject {
    /// What the sidebar selects: one value per page of the tool.
    associatedtype Destination: Hashable & Sendable
    associatedtype Detail: View
    associatedtype Toolbar: ToolbarContent
    associatedtype Inspector: View
    associatedtype ToolCommands: Commands = NoToolCommands
    /// Alerts, sheets, importers and drops the tool needs, applied around the whole window.
    associatedtype Dialogs: ViewModifier = EmptyModifier
    /// A sidebar row's context menu.
    associatedtype RowMenu: View = EmptyView

    var id: String { get }
    var title: String { get }
    var systemImage: String { get }
    /// The platforms the tool is offered on; a shell shows only the modules that include its own.
    var platforms: ToolPlatforms { get }

    /// The page showing, kept by the module so the shell can restore it.
    var selection: Destination? { get set }
    var isInspectorPresented: Bool { get set }

    /// The sidebar, as data: the shell draws it. Read from observable state, so it redraws when counts change.
    var sidebar: [ToolSidebarSection<Destination>] { get }

    /// The page for a sidebar choice, with whatever the tool shows on every page (a bottom bar, for example).
    @ViewBuilder func detail(for destination: Destination?) -> Detail

    /// Toolbar items the shell adds beside the page's own.
    @ToolbarContentBuilder func toolbar(for destination: Destination?) -> Toolbar

    /// Whether the page has an inspector; the shell hides the inspector column otherwise.
    func hasInspector(for destination: Destination?) -> Bool
    @ViewBuilder func inspector(for destination: Destination?) -> Inspector

    var dialogs: Dialogs { get }

    /// Extra menu commands for the tool.
    @CommandsBuilder var commands: ToolCommands { get }

    func hasContextMenu(for destination: Destination) -> Bool
    @ViewBuilder func contextMenu(for destination: Destination) -> RowMenu

    /// Files dropped on a sidebar row; false when the row takes none.
    func acceptsFileDrop(on destination: Destination) -> Bool
    func dropFiles(_ urls: [URL], on destination: Destination) -> Bool
}

extension ToolModule where ToolCommands == NoToolCommands {
    public var commands: NoToolCommands { NoToolCommands() }
}

extension ToolModule where Dialogs == EmptyModifier {
    public var dialogs: EmptyModifier { EmptyModifier() }
}

extension ToolModule where RowMenu == EmptyView {
    public func contextMenu(for destination: Destination) -> EmptyView { EmptyView() }
}

extension ToolModule {
    public var platforms: ToolPlatforms { .all }
    public func hasContextMenu(for destination: Destination) -> Bool { false }
    public func acceptsFileDrop(on destination: Destination) -> Bool { false }
    public func dropFiles(_ urls: [URL], on destination: Destination) -> Bool { false }

    /// Every page the sidebar can select, in order.
    public var selectableDestinations: [Destination] {
        ToolSidebarModel(sidebar).selectableDestinations
    }
}
