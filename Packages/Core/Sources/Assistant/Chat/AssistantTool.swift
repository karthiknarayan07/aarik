import Foundation

/// One input a tool takes. The model fills these in; every value reaches the tool as text.
public struct AssistantParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case string
        case integer
        case boolean
    }

    public let name: String
    public let summary: String
    public let kind: Kind
    /// When not empty, the only values the model may give.
    public let allowed: [String]

    public init(_ name: String, _ summary: String, kind: Kind = .string, allowed: [String] = []) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.allowed = allowed
    }
}

/// What the model passed to a tool, as text by parameter name. Missing and empty values are the same thing.
public struct AssistantArguments: Sendable, Equatable, Codable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func string(_ name: String) -> String? {
        guard let value = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    public func integer(_ name: String) -> Int? { string(name).flatMap { Int($0) } }
}

/// What a tool found or did: `text` goes back to the model; the rest is what the transcript's row shows.
public struct AssistantToolOutput: Sendable, Equatable {
    public var text: String
    /// The row's title in the past tense, in Title Case ("Searched Library").
    public var title: String
    /// Shown as "· 42 Results" after the title.
    public var count: Int?
    /// The lines under the row when it is opened.
    public var lines: [String]

    public init(text: String, title: String, count: Int? = nil, lines: [String] = []) {
        self.text = text
        self.title = title
        self.count = count
        self.lines = lines
    }
}

/// What the person is asked before an action runs ("Convert 14 Videos" / "Save about 6.2 GB?").
public struct AssistantConfirmation: Sendable, Equatable, Codable {
    public var title: String
    public var message: String
    /// The Confirm button's title, in Title Case.
    public var confirmLabel: String

    public init(title: String, message: String, confirmLabel: String = "Confirm") {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
    }
}

/// A tool could not do what was asked; the message goes to the model, which says it in its own words.
public struct AssistantToolError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Something the assistant can do. A tool that only reads runs on its own. A tool that acts (`requiresConfirmation`)
/// first describes what it would do; `run` is called only after the person taps Confirm, never otherwise.
public protocol AssistantTool: Sendable {
    /// The name the model calls it by: letters and underscores.
    var name: String { get }
    /// What it does, for the model.
    var summary: String { get }
    var parameters: [AssistantParameter] { get }
    /// True for anything that changes something (queue, pause, resume, Replace Originals).
    var requiresConfirmation: Bool { get }
    /// The card for an action. Throw `AssistantToolError` to say why it can't be done; the model is told.
    func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation
    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput
}

extension AssistantTool {
    public var parameters: [AssistantParameter] { [] }
    public var requiresConfirmation: Bool { false }
    public func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
        throw AssistantToolError("This tool doesn't need confirmation.")
    }
}

/// Where a tool contributes its assistant tools. Each tool module (Convert, and the ones to come) registers one with
/// the app's services; the Ask tab offers them all.
public protocol AssistantToolProvider: Sendable {
    func assistantTools() -> [any AssistantTool]
}
