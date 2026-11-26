/// The broad family a tool belongs to, used to group tools in the sidebar.
public enum ToolCategory: String, Codable, Sendable, CaseIterable {
    case video
    case image
    case pdf
    case documents
}

/// Static identity of a tool. Views are attached in the feature modules so that
/// AppCore stays free of UI.
public struct ToolDescriptor: Sendable, Hashable {
    public let id: String
    public let name: String
    public let symbol: String
    public let category: ToolCategory

    public init(id: String, name: String, symbol: String, category: ToolCategory) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.category = category
    }
}

public protocol Tool: Sendable {
    static var descriptor: ToolDescriptor { get }
}
