import Foundation
import Observation

/// The chat engine behind the Ask tab. It sends what the person types to the language model together with the tools
/// the app's tools contribute, streams the answer into the transcript as it arrives, and records each tool step.
///
/// The assistant may read freely: a tool that only reads runs on its own and shows as a row. A tool that acts waits
/// for a tap on its confirmation card; Cancel (or Stop, or closing the app) does nothing. Everything runs on the device.
@MainActor
@Observable
public final class AssistantChat {
    /// The transcript of the open chat.
    public private(set) var items: [ChatItem] = []
    /// True while an answer is being written. It ends while a confirmation card waits for a tap, so Send shows again.
    public var isGenerating: Bool { isWorking && !hasPendingConfirmation }
    private var isWorking = false
    /// The open chat; nil until the first message of a new chat is sent.
    public private(set) var currentID: UUID?
    public private(set) var conversations: [ChatConversationSummary] = []
    public let availability: AssistantAvailability
    /// What the next questions are about (a video chosen with Ask About This…). The model is told; the transcript
    /// shows only what the person typed. Cleared by a new chat, opening another chat, or `clearContext()`.
    public private(set) var context: ChatContext?

    @ObservationIgnored private let client: any LanguageModelClient
    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let tools: @MainActor () -> [any AssistantTool]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation: Task<Void, Never>?
    /// Changes whenever another chat is opened, so an answer still finishing for the old one writes nothing.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var decisions: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// The rules, headed by today's date so "last year" and "this year" mean something.
    static func instructions(today: Date) -> String {
        let year = Calendar.current.component(.year, from: today)
        let date = today.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return "Today is \(date). The current year is \(year); last year was \(year - 1).\n" + instructions
    }

    static let instructions = """
        You are the assistant inside a free, offline app that shrinks videos on this device. Help the person \
        understand their video library and free up space. This is an everyday, harmless task.

        Rules:
        - Call a tool to look anything up. Never guess sizes, counts, names or savings.
        - For how many videos there are, or how much space they take, call search_library with no arguments and \
        answer with the count and total size on its first line, not with the number of items listed.
        - For how much has been saved, call savings_so_far. For what could be freed, call estimate_savings.
        - Fill in a tool's arguments only with what the person said. Never add a name, year, size or library of your \
        own.
        - Answer only from what the tools returned. If a tool found nothing, say so.
        - When a tool returns a list, name every item it lists (name and size), then say how many more there are, \
        using the tool's number. If it says all are listed, there are no others. Never answer with only an \
        introduction.
        - If a tool says Photos access is off or not allowed yet, say that, not that the library is empty, and offer \
        to help turn it on with allow_photos_access.
        - Use only the numbers and names in the tool result. Never add counts, sizes or thresholds of your own.
        - If a tool says no videos were found, say so plainly. Don't list anything.
        - If a tool says the person cancelled, acknowledge it in one short sentence and stop. Don't repeat the \
        earlier answer or offer the action again.
        - Be brief and plain: a short sentence, then the list. No headings.
        - To start conversions, pause or resume the queue, or move originals, call the matching tool. The person is \
        asked to confirm first, so never say something was done until the tool's result says so. If the person \
        declines, accept it and don't ask again.

        Examples:
        Person: Find my biggest videos.
        You call search_library, then answer: "Your biggest videos are Beach Day (4.2 GB), Birthday (3.1 GB) and \
        Road Trip (2.8 GB)." Mention other videos only if the tool says some aren't listed, using its number.
        Person: How much space could I free?
        You call estimate_savings, then answer: "Converting could free about 38 GB. The biggest group is B1: 14 \
        videos from 2024, about 21 GB."
        Person: What is in the queue?
        You call list_queue, then answer with how many are waiting and the first few names.
        """

    /// What the model hears when the person cancels a card.
    static let cancelledNote =
        "The user cancelled; nothing changed. Acknowledge in one short sentence. Don't repeat the earlier answer."

    /// The short prompt for the one retry after a refusal: no history, no examples, only the job.
    static let simpleInstructions = """
        You help someone manage the video files in their own library on this device. Use the tools to look things \
        up, then answer briefly in plain words, naming the items and sizes the tools returned. Say only what the \
        tools told you.
        """

    public init(
        client: any LanguageModelClient, availability: AssistantAvailability, store: ChatStore,
        tools: @escaping @MainActor () -> [any AssistantTool], now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.now = now
        self.client = client
        self.availability = availability
        self.store = store
        self.tools = tools
        conversations = store.conversations()
    }

    /// The Ask tab's state: ready, or why the model can't be asked (it can drop while the app runs).
    public var unavailableReason: AssistantUnavailableReason? {
        availability.isAvailable ? nil : (availability.reason ?? .unknown)
    }

    public var hasPendingConfirmation: Bool {
        items.contains { if case .confirmation(let c) = $0.content { c.state == .pending } else { false } }
    }

    // MARK: Asking

    /// Sends the message and streams the answer. Does nothing for empty text, while an answer is being written, or
    /// while the model is unavailable.
    public func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating, availability.isAvailable else { return }
        // A card still waiting is answered by asking something else: it is cancelled and its answer set aside.
        if isWorking {
            stop()
            epoch += 1
        }
        let id = ensureConversation(startingWith: prompt)
        let history = Self.turns(items)
        append(.user(prompt), in: id)
        start(prompt: prompt, history: history, in: id)
    }

    private func start(prompt: String, history: [ChatTurn], in id: UUID) {
        isWorking = true
        let epoch = self.epoch
        generation = Task { [weak self] in
            await self?.generate(prompt: prompt, history: history, in: id, epoch: epoch)
        }
    }

    /// Whether the last reply (or the error that took its place) can be asked for again.
    public var canRegenerate: Bool {
        guard !isWorking, availability.isAvailable, let index = items.lastIndex(where: Self.isUser) else {
            return false
        }
        let after = items[(index + 1)...]
        guard let last = after.last else { return false }
        switch last.content {
        case .assistant, .notice: break
        default: return false
        }
        // An action that was confirmed has happened; asking again must not hide or repeat it.
        return !after.contains {
            if case .confirmation(let card) = $0.content {
                card.state == .confirmed || card.state == .failed
            } else {
                false
            }
        }
    }

    /// Replaces the last reply with a fresh one for the same message. Also what Retry does after an error.
    public func regenerate() {
        guard canRegenerate, let id = currentID, let index = items.lastIndex(where: Self.isUser),
            case .user(let prompt) = items[index].content
        else { return }
        let history = Self.turns(items[..<index])
        let removed = items[(index + 1)...].map(\.id)
        items.removeSubrange((index + 1)...)
        store.remove(removed, in: id)
        start(prompt: prompt, history: history, in: id)
    }

    private static func isUser(_ item: ChatItem) -> Bool {
        if case .user = item.content { true } else { false }
    }

    private static func turns(_ items: some Sequence<ChatItem>) -> [ChatTurn] {
        items.compactMap { item -> ChatTurn? in
            switch item.content {
            case .user(let text): ChatTurn(.user, text)
            case .assistant(let text): ChatTurn(.assistant, text)
            default: nil
            }
        }
    }

    /// Makes the next questions about this subject. Replaces any earlier one.
    public func setContext(_ context: ChatContext) { self.context = context }

    public func clearContext() { context = nil }

    /// Stops the answer being written. What was written stays; a waiting confirmation is cancelled, so nothing runs.
    public func stop() {
        generation?.cancel()
        resolvePending()
    }

    /// Returns when the current answer has finished. For tests.
    public func waitUntilIdle() async { await generation?.value }

    private func generate(prompt: String, history: [ChatTurn], in id: UUID, epoch: Int) async {
        var replyID: UUID?
        var failure: (any Error)?
        // A refusal is often the model misjudging an ordinary question, so it gets one more try with a plainer prompt.
        for attempt in 0..<2 {
            let simplified = attempt == 1
            let request = ChatRequest(
                prompt: prompt,
                instructions: (simplified ? Self.simpleInstructions : Self.instructions(today: now()))
                    + (context?.instructions ?? ""),
                history: simplified ? [] : history, tools: tools(),
                invoke: { [weak self] name, arguments in
                    await self?.handleToolCall(name, arguments, in: id) ?? "The assistant is closed."
                })
            failure = nil
            do {
                for try await text in client.streamChat(request) {
                    if Task.isCancelled { break }
                    if let existing = replyID {
                        update(existing) { $0.content = .assistant(text) }
                    } else if !text.isEmpty {
                        replyID = append(.assistant(text), in: id)
                    }
                }
            } catch is CancellationError {
            } catch {
                failure = error
            }
            guard (failure as? AssistantError) == .guardrail, replyID == nil, !Task.isCancelled else { break }
        }
        if let failure { append(.notice(Self.message(for: failure)), in: id) }
        // Whatever was written stays; a reply that ended up empty leaves no row.
        if let replyID, let item = items.first(where: { $0.id == replyID }) { persist(item, in: id) }
        guard epoch == self.epoch else { return }
        resolvePending()
        finishRunningRows(in: id)
        isWorking = false
        generation = nil
        conversations = store.conversations()
    }

    static func message(for error: any Error) -> String {
        switch error as? AssistantError {
        case .unavailable: "Apple Intelligence isn't available right now."
        case .guardrail: "I couldn't answer that one. Try asking it another way."
        case .contextTooLong: "This chat has grown too long. Start a new chat to keep going."
        case .rateLimited: "I'm busy right now. Try again in a moment."
        case .unsupportedLanguage: "I don't support this language yet."
        case .timedOut: "That took too long. Try again."
        default: "I couldn't finish that answer. Try again."
        }
    }

    // MARK: Tools

    private func handleToolCall(_ name: String, _ arguments: AssistantArguments, in id: UUID) async -> String {
        guard let tool = tools().first(where: { $0.name == name }) else { return "There is no tool named \(name)." }
        guard tool.requiresConfirmation else {
            let row = append(
                .toolCall(ChatToolCall(toolName: name, title: Self.humanized(name), state: .running)), in: id)
            do {
                let output = try await tool.run(arguments)
                finish(row, with: output, in: id)
                return output.text
            } catch {
                let message = (error as? AssistantToolError)?.message ?? "It didn't work."
                update(row) { $0.content = .toolCall(Self.failed($0, message)) }
                if let item = items.first(where: { $0.id == row }) { persist(item, in: id) }
                return message
            }
        }
        let card: AssistantConfirmation
        do {
            card = try await tool.confirmation(for: arguments)
        } catch {
            return (error as? AssistantToolError)?.message ?? "That can't be done right now."
        }
        let cardID = append(
            .confirmation(ChatConfirmation(toolName: name, arguments: arguments, card: card)), in: id)
        let approved = await withCheckedContinuation { decisions[cardID] = $0 }
        guard approved else { return Self.cancelledNote }
        do {
            let output = try await tool.run(arguments)
            updateConfirmation(cardID, in: id) { $0.result = output.text }
            return output.text
        } catch {
            let message = (error as? AssistantToolError)?.message ?? "It didn't work."
            updateConfirmation(cardID, in: id) {
                $0.state = .failed
                $0.result = message
            }
            return "It was confirmed but did not work: \(message)"
        }
    }

    /// Confirm on a card: the action runs now.
    public func confirm(_ cardID: UUID) {
        guard let decision = decisions.removeValue(forKey: cardID), let id = currentID else { return }
        updateConfirmation(cardID, in: id) { $0.state = .confirmed }
        decision.resume(returning: true)
    }

    /// Cancel on a card: nothing happens.
    public func cancel(_ cardID: UUID) {
        guard let decision = decisions.removeValue(forKey: cardID), let id = currentID else { return }
        updateConfirmation(cardID, in: id) { $0.state = .cancelled }
        decision.resume(returning: false)
    }

    private func resolvePending() {
        for cardID in Array(decisions.keys) { cancel(cardID) }
    }

    private func finish(_ row: UUID, with output: AssistantToolOutput, in id: UUID) {
        update(row) {
            $0.content = .toolCall(
                ChatToolCall(
                    toolName: Self.toolName($0), title: output.title, count: output.count, lines: output.lines,
                    state: .done))
        }
        if let item = items.first(where: { $0.id == row }) { persist(item, in: id) }
    }

    private func finishRunningRows(in id: UUID) {
        for item in items {
            guard case .toolCall(var call) = item.content, call.state == .running else { continue }
            call.state = .failed
            update(item.id) { $0.content = .toolCall(call) }
        }
    }

    private static func toolName(_ item: ChatItem) -> String {
        if case .toolCall(let call) = item.content { call.toolName } else { "" }
    }

    private static func failed(_ item: ChatItem, _ message: String) -> ChatToolCall {
        guard case .toolCall(var call) = item.content else { return ChatToolCall(toolName: "", title: message) }
        call.state = .failed
        call.lines = [message]
        return call
    }

    /// "search_library" as "Search Library", until the tool says what it did.
    static func humanized(_ name: String) -> String {
        name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Transcript

    @discardableResult
    private func append(_ content: ChatItem.Content, in id: UUID) -> UUID {
        let item = ChatItem(content)
        guard currentID == id else { return item.id }
        items.append(item)
        persist(item, in: id)
        return item.id
    }

    private func update(_ id: UUID, _ change: (inout ChatItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func updateConfirmation(_ cardID: UUID, in id: UUID, _ change: (inout ChatConfirmation) -> Void) {
        update(cardID) {
            guard case .confirmation(var confirmation) = $0.content else { return }
            change(&confirmation)
            $0.content = .confirmation(confirmation)
        }
        if let item = items.first(where: { $0.id == cardID }) { persist(item, in: id) }
    }

    private func persist(_ item: ChatItem, in id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        store.save(item, order: index, in: id)
    }

    // MARK: Chats

    private func ensureConversation(startingWith prompt: String) -> UUID {
        if let currentID { return currentID }
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let id = store.createConversation(title: String(line.prefix(48)))
        currentID = id
        return id
    }

    /// Starts an empty chat. The chat is saved when its first message is sent, so empty chats never pile up.
    public func newChat() {
        leaveChat()
        items = []
        currentID = nil
        context = nil
    }

    public func open(_ id: UUID) {
        guard id != currentID else { return }
        leaveChat()
        items = store.items(in: id)
        currentID = id
        context = nil
    }

    public func rename(_ id: UUID, to title: String) {
        store.rename(id, to: title)
        conversations = store.conversations()
    }

    /// Deletes the chat (and only the chat).
    public func delete(_ id: UUID) {
        if id == currentID { newChat() }
        store.delete(id)
        conversations = store.conversations()
    }

    public func refreshConversations() { conversations = store.conversations() }

    private func leaveChat() {
        stop()
        epoch += 1
        isWorking = false
        generation = nil
    }
}
