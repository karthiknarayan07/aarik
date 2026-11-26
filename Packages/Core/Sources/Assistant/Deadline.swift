import Foundation
import Synchronization

/// Runs a model request with a time limit. The request is cancelled when the limit passes, but the caller gets
/// `AssistantError.timedOut` at once even if the request ignores cancellation.
public enum Deadline {
    public static func run<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, limit: limit, operation: operation)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private final class Race<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, any Error>?
            var early: Result<T, any Error>?
            var finished = false
            var tasks: [Task<Void, Never>] = []
        }

        private let state = Mutex(State())

        func start(
            _ continuation: CheckedContinuation<T, any Error>, limit: Duration,
            operation: @escaping @Sendable () async throws -> T
        ) {
            let early = state.withLock { state -> Result<T, any Error>? in
                if state.finished { return state.early }
                state.continuation = continuation
                return nil
            }
            if let early {
                continuation.resume(with: early)
                return
            }
            let work = Task { [self] in
                do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
            }
            let timer = Task { [self] in
                try? await Task.sleep(for: limit)
                finish(.failure(AssistantError.timedOut))
            }
            let cancelNow = state.withLock { state -> Bool in
                if state.finished { return true }
                state.tasks = [work, timer]
                return false
            }
            if cancelNow {
                work.cancel()
                timer.cancel()
            }
        }

        func finish(_ result: Result<T, any Error>) {
            let (continuation, tasks) = state.withLock {
                state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
                guard !state.finished else { return (nil, []) }
                state.finished = true
                let continuation = state.continuation
                state.continuation = nil
                if continuation == nil { state.early = result }
                let tasks = state.tasks
                state.tasks = []
                return (continuation, tasks)
            }
            for task in tasks { task.cancel() }
            continuation?.resume(with: result)
        }
    }
}
