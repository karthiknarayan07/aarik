#if os(macOS)
    import SwiftUI

    /// No menu commands.
    public struct NoToolCommands: Commands {
        public init() {}
        public var body: some Commands { CommandGroup(after: .help) {} }
    }

    /// What a tool's UI gives the Mac shell: its sidebar, its screens, its toolbar and its inspector. The shell hosts
    /// one scene and knows nothing else of the tool: the scene also supplies the dialogs, file drops and sheets that
    /// belong to it. The shared services belong to the app and are given to the tool's model when it is made; the
    /// scene doesn't own them. It takes over what `ToolModule` carried (ADR 0006); the tool's identity, platforms and
    /// runners are the `Tool`'s.
    @MainActor
    public protocol MacToolScene: AnyObject {
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

        /// The tool this scene presents.
        var tool: any Tool { get }

        /// The page showing, kept by the scene so the shell can restore it.
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

    extension MacToolScene where ToolCommands == NoToolCommands {
        public var commands: NoToolCommands { NoToolCommands() }
    }

    extension MacToolScene where Dialogs == EmptyModifier {
        public var dialogs: EmptyModifier { EmptyModifier() }
    }

    extension MacToolScene where RowMenu == EmptyView {
        public func contextMenu(for destination: Destination) -> EmptyView { EmptyView() }
    }

    extension MacToolScene {
        public func hasContextMenu(for destination: Destination) -> Bool { false }
        public func acceptsFileDrop(on destination: Destination) -> Bool { false }
        public func dropFiles(_ urls: [URL], on destination: Destination) -> Bool { false }

        /// Every page the sidebar can select, in order.
        public var selectableDestinations: [Destination] {
            ToolSidebarModel(sidebar).selectableDestinations
        }
    }
#endif
