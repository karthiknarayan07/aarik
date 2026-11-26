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

    /// What VoiceOver says for the row.
    public var accessibilityText: String {
        if availability == .comingSoon { return "\(title), coming soon" }
        var text = count.map { "\(title), \($0)" } ?? title
        if let progress { text += ", converting \(Int((progress * 100).rounded()))%" }
        return text
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

/// No menu commands.
public struct NoToolCommands: Commands {
    public init() {}
    public var body: some Commands { CommandGroup(after: .help) {} }
}

/// What a tool gives the shell: its sidebar, its screens, its toolbar and its inspector. The shell hosts one module
/// and never names a tool's types. The shared services (queue, settings, updater, notifier) belong to the shell and
/// are passed to the module when it is made; the module doesn't own them.
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

    var id: String { get }
    var title: String { get }
    var systemImage: String { get }

    /// The page showing, kept by the module so the shell can restore it.
    var selection: Destination? { get set }

    /// The sidebar, as data: the shell draws it. Read from observable state, so it redraws when counts change.
    var sidebar: [ToolSidebarSection<Destination>] { get }

    /// The page for a sidebar choice.
    @ViewBuilder func detail(for destination: Destination?) -> Detail

    /// Toolbar items the shell adds beside the page's own.
    @ToolbarContentBuilder func toolbar(for destination: Destination?) -> Toolbar

    /// Whether the page has an inspector; the shell hides the inspector column otherwise.
    func hasInspector(for destination: Destination?) -> Bool
    @ViewBuilder func inspector(for destination: Destination?) -> Inspector

    /// Extra menu commands for the tool.
    @CommandsBuilder var commands: ToolCommands { get }
}

extension ToolModule where ToolCommands == NoToolCommands {
    public var commands: NoToolCommands { NoToolCommands() }
}

extension ToolModule {
    /// Every page the sidebar can select, in order.
    public var selectableDestinations: [Destination] {
        sidebar.flatMap(\.items).filter { $0.availability == .available }.compactMap(\.destination)
    }
}
