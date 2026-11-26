/// Where the iOS shell was: which tool, which of its pages, and which column (the Tools list, the pages or the
/// detail). It is stored as one string in `SceneStorage`, so a relaunch or a size class or posture change lands in the
/// same place. Anything it can't read falls back to the Tools list.
public struct ToolNavigationState: Equatable, Sendable {
    public enum Column: String, Sendable, CaseIterable {
        case tools
        case pages
        case detail
    }

    public var toolID: String?
    public var page: String?
    public var column: Column

    public init(toolID: String? = nil, page: String? = nil, column: Column = .tools) {
        self.toolID = toolID
        self.page = page
        self.column = column
    }

    private static let separator: Character = "|"

    public var stored: String {
        [toolID ?? "", page ?? "", column.rawValue].joined(separator: String(Self.separator))
    }

    public init(stored: String) {
        let parts = stored.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            self.init()
            return
        }
        self.init(
            toolID: parts[0].isEmpty ? nil : parts[0], page: parts[1].isEmpty ? nil : parts[1],
            column: Column(rawValue: parts[2]) ?? .tools)
    }

    /// The state with a tool that isn't offered dropped, so a stale id can't select nothing.
    public func restricted(to toolIDs: [String]) -> ToolNavigationState {
        guard let toolID, toolIDs.contains(toolID) else { return ToolNavigationState() }
        return self
    }
}
