import Foundation
import Testing

@testable import Assistant

@MainActor
struct ChatStoreTests {
    @Test func createsListsNewestFirstAndRenames() {
        let store = ChatStore(directory: nil)
        let first = store.createConversation(title: "First", now: Date(timeIntervalSince1970: 100))
        let second = store.createConversation(title: "Second", now: Date(timeIntervalSince1970: 200))
        #expect(store.conversations().map(\.id) == [second, first])
        store.rename(first, to: "  Big Videos  ")
        #expect(store.title(of: first) == "Big Videos")
        store.rename(first, to: "   ")
        #expect(store.title(of: first) == "Big Videos")
    }

    @Test func savesAndReadsItemsInOrderIncludingToolRowsAndCards() {
        let store = ChatStore(directory: nil)
        let id = store.createConversation()
        let user = ChatItem(.user("Find big videos"))
        let call = ChatItem(.toolCall(ChatToolCall(toolName: "search_library", title: "Searched Library", count: 42, lines: ["a"], state: .done)))
        let card = ChatItem(
            .confirmation(
                ChatConfirmation(
                    toolName: "queue_videos", arguments: AssistantArguments(["group": "B1"]),
                    card: AssistantConfirmation(title: "Convert 14 Videos", message: "Save about 6.2 GB?"),
                    state: .confirmed, result: "Queued 14.")))
        let reply = ChatItem(.assistant("Done."))
        for (order, item) in [user, call, card, reply].enumerated() { store.save(item, order: order, in: id) }
        #expect(store.items(in: id) == [user, call, card, reply])
        // Saving the same id again replaces it.
        var edited = reply
        edited.content = .assistant("Done, all 14.")
        store.save(edited, order: 3, in: id)
        #expect(store.items(in: id).last == edited)
        #expect(store.conversations().first?.preview == "Done, all 14.")
    }

    @Test func aRunningRowAndAPendingCardComeBackFinished() {
        let store = ChatStore(directory: nil)
        let id = store.createConversation()
        store.save(ChatItem(.toolCall(ChatToolCall(toolName: "t", title: "T", state: .running))), order: 0, in: id)
        store.save(
            ChatItem(
                .confirmation(
                    ChatConfirmation(toolName: "t", arguments: AssistantArguments(), card: AssistantConfirmation(title: "A", message: "B")))),
            order: 1, in: id)
        let items = store.items(in: id)
        guard case .toolCall(let call) = items[0].content, case .confirmation(let card) = items[1].content else {
            Issue.record("wrong kinds")
            return
        }
        #expect(call.state == .failed && card.state == .expired)
    }

    @Test func deletingAChatRemovesItsMessagesOnly() {
        let store = ChatStore(directory: nil)
        let keep = store.createConversation(title: "Keep")
        let drop = store.createConversation(title: "Drop")
        store.save(ChatItem(.user("a")), order: 0, in: keep)
        store.save(ChatItem(.user("b")), order: 0, in: drop)
        store.delete(drop)
        #expect(store.conversations().map(\.id) == [keep])
        #expect(store.items(in: drop).isEmpty)
        #expect(store.items(in: keep).count == 1)
    }

    @Test func persistsOnDisk() throws {
        let directory = URL.temporaryDirectory.appending(path: "chat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id: UUID
        do {
            let store = ChatStore(directory: directory)
            #expect(store.isPersistent)
            id = store.createConversation(title: "Saved")
            store.save(ChatItem(.user("hello")), order: 0, in: id)
        }
        let reopened = ChatStore(directory: directory)
        #expect(reopened.title(of: id) == "Saved")
        #expect(reopened.items(in: id).count == 1)
    }

    @Test func chatDeleteStartsAFreshChatWhenItWasOpen() async {
        let client = ScriptedChatClient { _ in [.text("ok")] }
        let chat = AssistantChat(
            client: client, availability: AssistantAvailability(client: client, observesActivation: false),
            store: ChatStore(directory: nil), tools: { [] })
        chat.send("Hello")
        await chat.waitUntilIdle()
        let id = chat.currentID!
        #expect(chat.conversations.map(\.id) == [id])
        chat.delete(id)
        #expect(chat.items.isEmpty && chat.currentID == nil && chat.conversations.isEmpty)
    }
}
