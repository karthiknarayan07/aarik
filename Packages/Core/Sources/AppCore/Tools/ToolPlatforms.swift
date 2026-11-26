/// The platforms a tool is offered on. An app shell shows only the tools whose platforms include its own.
public struct ToolPlatforms: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let macOS = ToolPlatforms(rawValue: 1 << 0)
    public static let iOS = ToolPlatforms(rawValue: 1 << 1)

    public static let all: ToolPlatforms = [.macOS, .iOS]
}

/// Which tools an app shell offers. There is no loading and no discovery (ADR 0004): the shell passes the tools it
/// can build and this keeps the ones for its platform.
public enum ToolRegistry {
    public static func tools(for platform: ToolPlatforms, from tools: [any Tool]) -> [any Tool] {
        tools.filter { $0.platforms.contains(platform) }
    }
}
