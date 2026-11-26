import Foundation
import FoundationModels
import Synchronization

/// A language model that follows a script instead of thinking: for tests, and for the Debug build's demo launch
/// (`-AssistantDemo`), which has no Apple Intelligence to rely on. Never used in a release path.
public final class ScriptedChatClient: LanguageModelClient {
    public enum Step: Sendable, Equatable {
        /// Writes the text a few characters at a time, so the stream shows partial answers.
        case text(String)
        /// Calls the tool as the model would, and waits for its result.
        case tool(String, [String: String] = [:])
    }

    private struct State {
        var isAvailable: Bool
        var reason: AssistantUnavailableReason?
        var requests: [ChatRequest] = []
        var toolResults: [String] = []
        var failures: [AssistantError] = []
    }

    private let state: Mutex<State>
    private let script: @Sendable (String) -> [Step]
    private let chunk: Int
    private let delay: Duration?

    /// `script` chooses the steps for each prompt. `chunk` is how many characters each streamed snapshot adds;
    /// `delay` pauses between them (the demo uses it so streaming is visible).
    public init(
        isAvailable: Bool = true, reason: AssistantUnavailableReason? = nil, chunk: Int = 6, delay: Duration? = nil,
        script: @escaping @Sendable (String) -> [Step]
    ) {
        state = Mutex(State(isAvailable: isAvailable, reason: reason))
        self.script = script
        self.chunk = max(1, chunk)
        self.delay = delay
    }

    public var isAvailable: Bool { state.withLock { $0.isAvailable } }
    public var unavailableReason: AssistantUnavailableReason? {
        state.withLock { $0.isAvailable ? nil : ($0.reason ?? .unknown) }
    }

    public func setAvailable(_ available: Bool, reason: AssistantUnavailableReason? = nil) {
        state.withLock {
            $0.isAvailable = available
            $0.reason = reason
        }
    }

    /// The next chat requests fail with these errors, one each, before the script is followed again.
    public func failNext(_ errors: AssistantError...) { state.withLock { $0.failures += errors } }

    /// The chat requests received, oldest first.
    public var requests: [ChatRequest] { state.withLock { $0.requests } }
    /// What each tool call came back with, in order.
    public var toolResults: [String] { state.withLock { $0.toolResults } }

    public func respond(to prompt: String, instructions: String) async throws -> String {
        guard isAvailable else { throw AssistantError.unavailable }
        return script(prompt).compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    public func generate<T: Generable & Sendable>(_ prompt: String, instructions: String) async throws -> T {
        throw AssistantError.failed
    }

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<String, any Error> {
        let failure: AssistantError? = state.withLock {
            $0.requests.append(request)
            return $0.failures.isEmpty ? nil : $0.failures.removeFirst()
        }
        let steps = script(request.prompt)
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                guard isAvailable else {
                    continuation.finish(throwing: AssistantError.unavailable)
                    return
                }
                var written = ""
                for step in steps {
                    if Task.isCancelled { break }
                    switch step {
                    case .tool(let name, let arguments):
                        let result = await request.invoke(name, AssistantArguments(arguments))
                        state.withLock { $0.toolResults.append(result) }
                    case .text(let text):
                        var index = text.startIndex
                        while index < text.endIndex, !Task.isCancelled {
                            index = text.index(index, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
                            continuation.yield(written + String(text[..<index]))
                            if let delay { try? await Task.sleep(for: delay) }
                        }
                        written += text
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
