import Foundation

/// A tool the model used, as one row of the transcript ("Searched Library · 42 Results").
public struct ChatToolCall: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case running, done, failed }
    public var toolName: String
    public var title: String
    public var count: Int?
    public var lines: [String]
    public var state: State

    public init(toolName: String, title: String, count: Int? = nil, lines: [String] = [], state: State = .running) {
        self.toolName = toolName
        self.title = title
        self.count = count
        self.lines = lines
        self.state = state
    }
}

/// An action waiting for a tap, and later how it ended.
public struct ChatConfirmation: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case pending, confirmed, cancelled, failed
        /// The app closed before the person answered: nothing was done and the card can't be used any more.
        case expired
    }
    public var toolName: String
    public var arguments: AssistantArguments
    public var card: AssistantConfirmation
    public var state: State
    /// What happened after Confirm, or why it couldn't.
    public var result: String?

    public init(
        toolName: String, arguments: AssistantArguments, card: AssistantConfirmation, state: State = .pending,
        result: String? = nil
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.card = card
        self.state = state
        self.result = result
    }
}

/// One entry of a chat, in order.
public struct ChatItem: Identifiable, Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case user(String)
        case assistant(String)
        case toolCall(ChatToolCall)
        case confirmation(ChatConfirmation)
        /// An explanation in the chat's own voice (the answer failed, the model went away).
        case notice(String)
    }

    public let id: UUID
    public var content: Content

    public init(id: UUID = UUID(), _ content: Content) {
        self.id = id
        self.content = content
    }
}

/// The subject of a chat, from "Ask About This…": a short title for the chip above the composer, and the facts the
/// model is given about it. Nothing here is written to the transcript.
public struct ChatContext: Sendable, Equatable {
    public var title: String
    public var details: String

    public init(title: String, details: String) {
        self.title = title
        self.details = details
    }

    /// Appended to the model's rules while the context is set.
    var instructions: String {
        "\n\nThe person is asking about this video unless they say otherwise: \(title). \(details) "
            + "Use the tools to look up more about it by name."
    }
}

/// A chat in the history list.
public struct ChatConversationSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var updatedAt: Date
    public var preview: String
}
