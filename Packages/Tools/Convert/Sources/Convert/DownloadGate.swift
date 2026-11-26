import Foundation

/// Lets one iCloud download (or other Photos fetch) run at a time, whatever the queue's concurrency: several
/// downloads at once only fight over the same connection. Waiters hold no thread, are served in arrival order, and
/// leave at once when their task is cancelled (a waiting job can be cancelled without ever downloading).
actor DownloadGate {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    /// Runs `body` once the gate is this caller's, then hands it on. Calls `onWait` atomically inside the actor if
    /// another fetch already holds the gate. Throws `CancellationError` if cancelled while waiting.
    func run<T: Sendable>(
        onWait: (@Sendable () -> Void)? = nil, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(onWait: onWait)
        defer { release() }
        return try await body()
    }

    private func acquire(onWait: (@Sendable () -> Void)?) async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        onWait?()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    var isBusy: Bool { busy }
    var waitingCount: Int { waiters.count }
}
