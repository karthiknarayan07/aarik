#if os(macOS)
    import SwiftUI

    /// No menu commands.
    public struct NoToolCommands: Commands {
        public init() {}
        public var body: some Commands { CommandGroup(after: .help) {} }
    }

    /// What a tool's UI gives the Mac shell: its pages, its toolbar items and its inspector. The shell owns Home, Ask and
    /// the Tools section of the sidebar; the scene lists only its own pages, which the shell nests under the tool's row.
    /// The scene also supplies the dialogs, file drops and sheets that belong to the tool. The shared services belong to the app and are given to the tool's model when it is made; the
    /// scene doesn't own them. It takes over what `ToolModule` carried (ADR 0006); the tool's identity, platforms and
    /// runners are the `Tool`'s.
    @MainActor
    public protocol MacToolScene: AnyObject {
        /// What the sidebar selects: one value per page of the tool.
        associatedtype Destination: Hashable & Sendable
        associatedtype Detail: View
        /// The app-level savings summary the shell shows as Home.
        associatedtype Home: View
        /// A bar on every page, Home and Ask included (originals waiting for deletion, for example).
        associatedtype BottomBar: View = EmptyView
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
        var selection: MacShellPage<Destination>? { get set }
        var isInspectorPresented: Bool { get set }

        /// The colour of the tool's symbol on its sidebar row.
        var sidebarTint: SidebarTint { get }

        /// The tool's own pages, as data: the shell draws them under the tool's row. Read from observable state, so it
        /// redraws when counts change. Home and Ask are the shell's and are not listed here.
        var sidebar: [ToolSidebarSection<Destination>] { get }

        /// The Home page: the savings summary of the tool's work.
        @ViewBuilder func homeSummary() -> Home

        /// The tool's page for a sidebar choice.
        @ViewBuilder func detail(for destination: Destination?) -> Detail

        @ViewBuilder func bottomBar() -> BottomBar

        /// Toolbar items the tool adds. The shell adds its own (New Chat, the inspector button) and keeps the set the
        /// same on every page, so the title bar's height never changes.
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

    extension MacToolScene where BottomBar == EmptyView {
        public func bottomBar() -> EmptyView { EmptyView() }
    }

    extension MacToolScene where RowMenu == EmptyView {
        public func contextMenu(for destination: Destination) -> EmptyView { EmptyView() }
    }

    extension MacToolScene {
        public func hasContextMenu(for destination: Destination) -> Bool { false }
        public func acceptsFileDrop(on destination: Destination) -> Bool { false }
        public func dropFiles(_ urls: [URL], on destination: Destination) -> Bool { false }

        /// Every page of the tool the sidebar can select, in order.
        public var selectableDestinations: [Destination] {
            ToolSidebarModel(sidebar).selectableDestinations
        }

        /// Whether the page showing has an inspector column. Home has none (the tool's item inspector has nothing to
        /// show there); Ask's is the shell's chat history. The window's frame is the user's, so hiding it moves nothing.
        public func hasInspector(on page: MacShellPage<Destination>?) -> Bool {
            switch page {
            case .home: false
            case .ask: true
            case .page(let destination): hasInspector(for: destination)
            case nil: hasInspector(for: nil)
            }
        }
    }
#endif
