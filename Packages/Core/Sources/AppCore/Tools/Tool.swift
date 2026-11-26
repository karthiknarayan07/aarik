import Foundation

/// The broad family a tool belongs to, used to group tools in the sidebar.
public enum ToolCategory: String, Codable, Sendable, CaseIterable {
    case video
    case image
    case pdf
    case documents
}

/// How a tool is listed before it can run (a sidebar row): its name, symbol and family.
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

/// One kind of job a tool runs. Its raw value is the `toolID` stored in every saved job, so it never changes once a
/// build has shipped.
public struct JobKind: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// What a `Job` carries as its `toolID`.
    public var toolID: String { rawValue }
}

/// Something a person gives a tool to work on, before it is a job: a file, or an item in the Photos library.
public enum MediaInput: Sendable, Equatable {
    case file(URL)
    case photosAsset(identifier: String, isVideo: Bool)
}

/// A tool as the core sees it: who it is, where it is offered, what it takes and how to run its jobs. There is no
/// SwiftUI here. Each platform's scene (`MacToolScene`, `IOSToolScene`) lives with the tool's UI. This is a boundary,
/// not a plugin system (ADR 0004, ADR 0006).
public protocol Tool: Sendable {
    var id: String { get }
    /// The name people see, in Title Case.
    var title: String { get }
    var systemImage: String { get }
    /// The platforms the tool is offered on; a shell shows only the tools that include its own.
    var platforms: ToolPlatforms { get }
    /// The kinds of job the tool runs, each with its own runner.
    var jobKinds: [JobKind] { get }

    /// Whether the tool can work on this input.
    func accepts(_ input: MediaInput) -> Bool
    /// The runner for one of the tool's job kinds; nil for a kind it doesn't run.
    func runner(for kind: JobKind) -> (any JobRunner)?
}

extension Tool {
    public var platforms: ToolPlatforms { .all }
    public var jobKinds: [JobKind] { [] }
    public func accepts(_ input: MediaInput) -> Bool { false }
    public func runner(for kind: JobKind) -> (any JobRunner)? { nil }
}
