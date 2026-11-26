import Foundation

/// A page of the Mac main window: the shell's own Home and Ask, or one of the hosted tool's pages.
public enum MacShellPage<Destination: Hashable & Sendable>: Hashable, Sendable {
    /// The app-level summary the tool provides (`MacToolScene.homeSummary()`).
    case home
    /// The assistant chat; listed only while Apple Intelligence is available.
    case ask
    /// A page the hosted tool lists under its own row in the Tools section.
    case page(Destination)

    /// The tool's page, nil for Home and Ask.
    public var destination: Destination? {
        if case .page(let destination) = self { destination } else { nil }
    }
}

/// What the Mac sidebar lists: Home, Ask (when available) and the tool's pages as one group under Tools. The shell
/// draws it and asks this type, so the decisions are testable without a window.
public struct MacSidebarModel<Destination: Hashable & Sendable>: Equatable {
    public let showsAsk: Bool
    /// The tool's pages, in its own order.
    public let tool: ToolSidebarModel<Destination>

    public init(showsAsk: Bool, tool sections: [ToolSidebarSection<Destination>]) {
        self.showsAsk = showsAsk
        self.tool = ToolSidebarModel(sections)
    }

    /// The tool's rows, flat: the tool's group has no sub-headings.
    public var toolRows: [ToolSidebarModel<Destination>.Row] { tool.sections.flatMap(\.rows) }

    /// Every page the sidebar can select, top to bottom.
    public var selectablePages: [MacShellPage<Destination>] {
        [.home] + (showsAsk ? [.ask] : []) + tool.selectableDestinations.map(MacShellPage.page)
    }

    /// Whether a click may change the selection to this: a listed row, or nothing.
    public func accepts(_ page: MacShellPage<Destination>?) -> Bool {
        page.map(selectablePages.contains) ?? true
    }
}
