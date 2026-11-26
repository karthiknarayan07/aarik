import Foundation
import SwiftData

@Model final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \MessageRecord.conversation) var messages: [MessageRecord] = []

    init(id: UUID, title: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

@Model final class MessageRecord {
    @Attribute(.unique) var id: UUID
    var conversation: ConversationRecord?
    var order: Int
    /// "user", "assistant", "toolCall", "confirmation" or "notice".
    var kind: String
    var text: String
    /// The encoded tool call or confirmation.
    var payload: Data?

    init(id: UUID, order: Int, kind: String, text: String, payload: Data?) {
        self.id = id
        self.order = order
        self.kind = kind
        self.text = text
        self.payload = payload
    }
}

/// The chat history: conversations and their messages, including tool-call rows and confirmation cards, in a
/// SwiftData store. This is the person's own data, so a store that can't be opened is never deleted: the chat
/// works from memory for this launch (`isPersistent` says so). Deleting removes chats only, never media or jobs.
@MainActor
public final class ChatStore {
    public static let fileName = "Assistant.store"

    private let container: ModelContainer
    /// False when the store on disk couldn't be opened and this launch keeps its chats in memory.
    public let isPersistent: Bool
    private var context: ModelContext { container.mainContext }

    /// `directory` holds the store file; nil keeps everything in memory (tests).
    public init(directory: URL?) {
        let schema = Schema([ConversationRecord.self, MessageRecord.self])
        if let directory,
            let container = try? ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: directory.appending(path: Self.fileName)))
        {
            self.container = container
            self.isPersistent = true
        } else {
            // Falls back to memory; an in-memory container always opens.
            self.container = try! ModelContainer(  // swiftlint:disable:this force_try
                for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            self.isPersistent = directory == nil
        }
    }

    // MARK: Conversations

    /// Newest activity first.
    public func conversations() -> [ChatConversationSummary] {
        let records =
            (try? context.fetch(
                FetchDescriptor<ConversationRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return records.map { record in
            let last = record.messages.filter { $0.kind == "assistant" || $0.kind == "user" }.max {
                $0.order < $1.order
            }
            return ChatConversationSummary(
                id: record.id, title: record.title, updatedAt: record.updatedAt, preview: last?.text ?? "")
        }
    }

    @discardableResult
    public func createConversation(title: String = "New Chat", now: Date = .now) -> UUID {
        let record = ConversationRecord(id: UUID(), title: title, createdAt: now)
        context.insert(record)
        save()
        return record.id
    }

    public func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let record = conversation(id) else { return }
        record.title = trimmed
        save()
    }

    /// Deletes the chat and its messages. Nothing else.
    public func delete(_ id: UUID) {
        guard let record = conversation(id) else { return }
        context.delete(record)
        save()
    }

    public func title(of id: UUID) -> String? { conversation(id)?.title }

    // MARK: Messages

    /// The chat's items in order. A card still waiting for a tap, or a tool still running, when the app closed can
    /// no longer finish: it comes back as expired or failed.
    public func items(in id: UUID) -> [ChatItem] {
        guard let record = conversation(id) else { return [] }
        return record.messages.sorted { $0.order < $1.order }.compactMap(Self.item(from:))
    }

    /// Adds the item, or replaces the one with the same id.
    public func save(_ item: ChatItem, order: Int, in id: UUID, now: Date = .now) {
        guard let conversation = conversation(id) else { return }
        let (kind, text, payload) = Self.encode(item.content)
        let itemID = item.id
        let existing = try? context.fetch(FetchDescriptor<MessageRecord>(predicate: #Predicate { $0.id == itemID }))
            .first
        if let existing {
            existing.order = order
            existing.kind = kind
            existing.text = text
            existing.payload = payload
        } else {
            let record = MessageRecord(id: item.id, order: order, kind: kind, text: text, payload: payload)
            record.conversation = conversation
            context.insert(record)
        }
        conversation.updatedAt = now
        save()
    }

    // MARK: Encoding

    private func conversation(_ id: UUID) -> ConversationRecord? {
        try? context.fetch(FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func save() { try? context.save() }

    private static func encode(_ content: ChatItem.Content) -> (String, String, Data?) {
        switch content {
        case .user(let text): ("user", text, nil)
        case .assistant(let text): ("assistant", text, nil)
        case .notice(let text): ("notice", text, nil)
        case .toolCall(let call): ("toolCall", call.title, try? JSONEncoder().encode(call))
        case .confirmation(let confirmation):
            ("confirmation", confirmation.card.title, try? JSONEncoder().encode(confirmation))
        }
    }

    private static func item(from record: MessageRecord) -> ChatItem? {
        let content: ChatItem.Content
        switch record.kind {
        case "user": content = .user(record.text)
        case "assistant": content = .assistant(record.text)
        case "notice": content = .notice(record.text)
        case "toolCall":
            guard var call = record.payload.flatMap({ try? JSONDecoder().decode(ChatToolCall.self, from: $0) }) else {
                return nil
            }
            if call.state == .running { call.state = .failed }
            content = .toolCall(call)
        case "confirmation":
            guard
                var confirmation = record.payload.flatMap({ try? JSONDecoder().decode(ChatConfirmation.self, from: $0) }
                )
            else { return nil }
            if confirmation.state == .pending { confirmation.state = .expired }
            content = .confirmation(confirmation)
        default: return nil
        }
        return ChatItem(id: record.id, content)
    }
}
