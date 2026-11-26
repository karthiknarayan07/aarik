import Foundation
import Synchronization
import Testing

@testable import Assistant

/// Counts how often it ran, so a test can prove an action did or didn't happen.
private final class CountingTool: AssistantTool, Sendable {
    let name: String
    let requiresConfirmation: Bool
    private let runs = Mutex(0)
    var runCount: Int { runs.withLock { $0 } }

    init(name: String, requiresConfirmation: Bool) {
        self.name = name
        self.requiresConfirmation = requiresConfirmation
    }

    var summary: String { "Test tool." }
    var parameters: [AssistantParameter] { [AssistantParameter("group", "A group.")] }

    func confirmation(for arguments: AssistantArguments) async throws -> AssistantConfirmation {
        AssistantConfirmation(title: "Convert 14 Videos", message: "Save about 6.2 GB?")
    }

    func run(_ arguments: AssistantArguments) async throws -> AssistantToolOutput {
        runs.withLock { $0 += 1 }
        return AssistantToolOutput(text: "ran \(name)", title: "Searched Library", count: 42, lines: ["a", "b"])
    }
}

@MainActor
private func makeChat(
    client: ScriptedChatClient, tools: [any AssistantTool] = []
) -> AssistantChat {
    AssistantChat(
        client: client, availability: AssistantAvailability(client: client, observesActivation: false),
        store: ChatStore(directory: nil), tools: { tools })
}

@MainActor
struct AssistantChatTests {
    @Test func streamsTheReplyIntoOneRow() async {
        let client = ScriptedChatClient(chunk: 4) { _ in [.text("Hello there, friend.")] }
        let chat = makeChat(client: client)
        chat.send("Hi")
        #expect(chat.isGenerating)
        await chat.waitUntilIdle()
        #expect(!chat.isGenerating)
        #expect(chat.items.map(\.content) == [.user("Hi"), .assistant("Hello there, friend.")])
    }

    @Test func aReadToolRunsOnItsOwn() async {
        let tool = CountingTool(name: "search_library", requiresConfirmation: false)
        let client = ScriptedChatClient { _ in [.tool("search_library"), .text("Found them.")] }
        let chat = makeChat(client: client, tools: [tool])
        chat.send("Find videos")
        await chat.waitUntilIdle()
        #expect(tool.runCount == 1)
        #expect(!chat.hasPendingConfirmation)
        guard case .toolCall(let call) = chat.items[1].content else {
            Issue.record("expected a tool row")
            return
        }
        #expect(call.title == "Searched Library" && call.count == 42 && call.state == .done)
        #expect(chat.items.last?.content == .assistant("Found them."))
        #expect(client.toolResults == ["ran search_library"])
    }

    @Test func anActionWaitsForConfirmationThenRuns() async {
        let tool = CountingTool(name: "queue_videos", requiresConfirmation: true)
        let client = ScriptedChatClient { _ in [.tool("queue_videos"), .text("Queued.")] }
        let chat = makeChat(client: client, tools: [tool])
        chat.send("Convert them")
        while !chat.hasPendingConfirmation { await Task.yield() }
        #expect(tool.runCount == 0)
        guard case .confirmation(let pending) = chat.items[1].content else {
            Issue.record("expected a card")
            return
        }
        #expect(pending.card.title == "Convert 14 Videos" && pending.state == .pending)
        chat.confirm(chat.items[1].id)
        await chat.waitUntilIdle()
        #expect(tool.runCount == 1)
        guard case .confirmation(let done) = chat.items[1].content else { return }
        #expect(done.state == .confirmed)
        #expect(client.toolResults == ["ran queue_videos"])
    }

    @Test func cancelDoesNothing() async {
        let tool = CountingTool(name: "queue_videos", requiresConfirmation: true)
        let client = ScriptedChatClient { _ in [.tool("queue_videos"), .text("Okay.")] }
        let chat = makeChat(client: client, tools: [tool])
        chat.send("Convert them")
        while !chat.hasPendingConfirmation { await Task.yield() }
        chat.cancel(chat.items[1].id)
        await chat.waitUntilIdle()
        #expect(tool.runCount == 0)
        guard case .confirmation(let card) = chat.items[1].content else { return }
        #expect(card.state == .cancelled)
        #expect(client.toolResults == [AssistantChat.cancelledNote])
    }

    @Test func stopCancelsAWaitingConfirmation() async {
        let tool = CountingTool(name: "queue_videos", requiresConfirmation: true)
        let client = ScriptedChatClient { _ in [.tool("queue_videos")] }
        let chat = makeChat(client: client, tools: [tool])
        chat.send("Convert them")
        while !chat.hasPendingConfirmation { await Task.yield() }
        chat.stop()
        await chat.waitUntilIdle()
        #expect(tool.runCount == 0)
        #expect(!chat.isGenerating)
        guard case .confirmation(let card) = chat.items[1].content else { return }
        #expect(card.state == .cancelled)
    }

    @Test func unavailableModelSendsNothing() async {
        let client = ScriptedChatClient(isAvailable: false, reason: .modelNotReady) { _ in [.text("x")] }
        let chat = makeChat(client: client)
        #expect(chat.unavailableReason == .modelNotReady)
        chat.send("Hi")
        #expect(chat.items.isEmpty && !chat.isGenerating && client.requests.isEmpty)
    }

    @Test func availabilityDroppingMidSessionShowsTheReason() {
        let client = ScriptedChatClient { _ in [] }
        let availability = AssistantAvailability(client: client, observesActivation: false)
        #expect(availability.isAvailable && availability.reason == nil)
        client.setAvailable(false, reason: .notEnabled)
        availability.refresh()
        #expect(!availability.isAvailable && availability.reason == .notEnabled)
    }

    @Test func aSecondQuestionCarriesTheChatSoFar() async {
        let client = ScriptedChatClient { prompt in [.text("Re: \(prompt)")] }
        let chat = makeChat(client: client)
        chat.send("One")
        await chat.waitUntilIdle()
        chat.send("Two")
        await chat.waitUntilIdle()
        #expect(client.requests[1].history == [ChatTurn(.user, "One"), ChatTurn(.assistant, "Re: One")])
    }

    @Test func historyPersistsToolRowsAndExpiresOldCards() async {
        let tool = CountingTool(name: "queue_videos", requiresConfirmation: true)
        let client = ScriptedChatClient { _ in [.tool("queue_videos")] }
        let store = ChatStore(directory: nil)
        let chat = AssistantChat(
            client: client, availability: AssistantAvailability(client: client, observesActivation: false),
            store: store, tools: { [tool] })
        chat.send("Convert them")
        while !chat.hasPendingConfirmation { await Task.yield() }
        let id = chat.currentID!
        // As if the app closed here: a fresh read finds the card unusable.
        guard case .confirmation(let card) = store.items(in: id)[1].content else {
            Issue.record("card not saved")
            return
        }
        #expect(card.state == .expired)
        chat.stop()
        await chat.waitUntilIdle()
    }

    @Test func aWaitingCardEndsGeneratingAndSendingAgainSetsItAside() async {
        let tool = CountingTool(name: "queue_videos", requiresConfirmation: true)
        let client = ScriptedChatClient { prompt in
            prompt == "Convert them" ? [.tool("queue_videos")] : [.text("Sure.")]
        }
        let chat = makeChat(client: client, tools: [tool])
        chat.send("Convert them")
        while !chat.hasPendingConfirmation { await Task.yield() }
        #expect(!chat.isGenerating)
        chat.send("Never mind")
        await chat.waitUntilIdle()
        #expect(tool.runCount == 0)
        guard case .confirmation(let card) = chat.items[1].content else { return }
        #expect(card.state == .cancelled)
        #expect(chat.items.last?.content == .assistant("Sure."))
        #expect(!chat.isGenerating)
    }

    @Test func aRefusalIsRetriedOnceWithASimplerPrompt() async {
        let client = ScriptedChatClient { _ in [.text("About 38 GB.")] }
        client.failNext(.guardrail)
        let chat = makeChat(client: client)
        chat.send("How much could I save?")
        await chat.waitUntilIdle()
        #expect(client.requests.count == 2)
        #expect(client.requests[1].instructions == AssistantChat.simpleInstructions)
        #expect(client.requests[1].history.isEmpty)
        #expect(chat.items.map(\.content) == [.user("How much could I save?"), .assistant("About 38 GB.")])
    }

    @Test func aSecondRefusalShowsTheNotice() async {
        let client = ScriptedChatClient { _ in [.text("x")] }
        client.failNext(.guardrail, .guardrail)
        let chat = makeChat(client: client)
        chat.send("Hi")
        await chat.waitUntilIdle()
        #expect(client.requests.count == 2)
        #expect(chat.items.last?.content == .notice(AssistantChat.message(for: AssistantError.guardrail)))
    }

    @Test func regenerateReplacesTheLastReply() async {
        let client = ScriptedChatClient { _ in [.text("Answer.")] }
        let chat = makeChat(client: client)
        chat.send("One")
        await chat.waitUntilIdle()
        let first = chat.items[1].id
        #expect(chat.canRegenerate)
        chat.regenerate()
        await chat.waitUntilIdle()
        #expect(chat.items.count == 2 && chat.items[1].id != first)
        #expect(client.requests.count == 2 && client.requests[1].history.isEmpty)
    }

    @Test func retryAfterAnErrorAsksAgain() async {
        let client = ScriptedChatClient { _ in [.text("Fine.")] }
        client.failNext(.failed)
        let chat = makeChat(client: client)
        chat.send("Hi")
        await chat.waitUntilIdle()
        guard case .notice = chat.items.last?.content else {
            Issue.record("expected a notice")
            return
        }
        #expect(chat.canRegenerate)
        chat.regenerate()
        await chat.waitUntilIdle()
        #expect(chat.items.map(\.content) == [.user("Hi"), .assistant("Fine.")])
    }

    @Test func aConfirmedActionCannotBeRegenerated() async {
        let tool = CountingTool(name: "queue_videos", requiresConfirmation: true)
        let client = ScriptedChatClient { _ in [.tool("queue_videos"), .text("Queued.")] }
        let chat = makeChat(client: client, tools: [tool])
        chat.send("Convert them")
        while !chat.hasPendingConfirmation { await Task.yield() }
        chat.confirm(chat.items[1].id)
        await chat.waitUntilIdle()
        #expect(!chat.canRegenerate)
    }
}
