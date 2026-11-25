import Foundation
import FoundationModels
import Synchronization

@testable import Assistant

/// A scripted model: unit tests never need the real one.
final class FakeLanguageModelClient: LanguageModelClient {
    typealias Handler = @Sendable (_ prompt: String, _ instructions: String) async throws -> Any

    private struct State {
        var isAvailable = true
        var handler: Handler?
        var prompts: [String] = []
        var instructions: [String] = []
    }

    private let state = Mutex(State())

    init(isAvailable: Bool = true, handler: Handler? = nil) {
        state.withLock {
            $0.isAvailable = isAvailable
            $0.handler = handler
        }
    }

    /// Always answers with `value`.
    convenience init(returning value: some Sendable) {
        self.init { _, _ in value }
    }

    var isAvailable: Bool {
        get { state.withLock(\.isAvailable) }
        set { state.withLock { $0.isAvailable = newValue } }
    }

    var prompts: [String] { state.withLock(\.prompts) }
    var instructions: [String] { state.withLock(\.instructions) }
    var callCount: Int { prompts.count }

    private func answer(_ prompt: String, _ instructions: String) async throws -> Any {
        let handler = state.withLock { state -> Handler? in
            state.prompts.append(prompt)
            state.instructions.append(instructions)
            return state.handler
        }
        guard let handler else { throw AssistantError.failed }
        return try await handler(prompt, instructions)
    }

    func respond(to prompt: String, instructions: String) async throws -> String {
        guard let text = try await answer(prompt, instructions) as? String else { throw AssistantError.failed }
        return text
    }

    func generate<T: Generable & Sendable>(_ prompt: String, instructions: String) async throws -> T {
        guard let value = try await answer(prompt, instructions) as? T else { throw AssistantError.failed }
        return value
    }
}

/// A request that never finishes and ignores cancellation, as a stuck model would.
func hangForever() async throws -> Any {
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    return ()
}
