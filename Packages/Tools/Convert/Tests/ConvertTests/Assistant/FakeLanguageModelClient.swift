import Foundation
import FoundationModels
import Synchronization

@testable import Convert
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

/// Records whether a cooperative request saw its cancellation.
final class CancellationProbe: Sendable {
    private let state = Mutex((started: false, cancelled: false))

    var started: Bool { state.withLock(\.started) }
    var wasCancelled: Bool { state.withLock(\.cancelled) }

    /// Waits until cancelled, checking `Task.isCancelled` and `Task.checkCancellation()` as a well-behaved
    /// model call does, and throws what it was cancelled with.
    func waitUntilCancelled() async throws -> Any {
        state.withLock { $0.started = true }
        do {
            while true {
                if Task.isCancelled { throw CancellationError() }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            state.withLock { $0.cancelled = true }
            throw error
        }
    }

    /// Polls until the request saw its cancellation, or `limit` passes.
    func waitForCancellation(within limit: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if wasCancelled { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return wasCancelled
    }
}
