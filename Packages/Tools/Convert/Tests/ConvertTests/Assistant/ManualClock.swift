import Foundation
import Synchronization

@testable import Assistant

/// A clock a test moves by hand: `sleep` suspends until `advance(by:)` has moved time to its deadline, so
/// debounce and retry timing run without any real waiting. Cancelling a sleeping task wakes it with
/// `CancellationError`, as a real sleep does.
final class ManualClock: Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Duration.zero
        var nextID = 0
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    var now: Duration { state.withLock(\.now) }

    /// How many sleeps are waiting for time to pass.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// The clock as the picks store takes it.
    var smartPicksClock: SmartPicksClock {
        SmartPicksClock(now: { self.now }, sleep: { try await self.sleep($0) })
    }

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Next {
                    case resume
                    case cancel
                    case waiting([CheckedContinuation<Void, Never>])
                }
                let next = state.withLock { state -> Next in
                    if Task.isCancelled { return .cancel }
                    if duration <= .zero { return .resume }
                    state.sleepers.append(
                        Sleeper(id: id, deadline: state.now + duration, continuation: continuation))
                    let ready = state.waiters.filter { state.sleepers.count >= $0.count }
                    state.waiters.removeAll { waiter in state.sleepers.count >= waiter.count }
                    return .waiting(ready.map(\.continuation))
                }
                switch next {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .waiting(let ready): ready.forEach { $0.resume() }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleep whose deadline has passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += duration
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    /// Returns once at least `count` sleeps are waiting.
    func waitForSleepers(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Holds a model call until the test lets it go, so a test can change things while a request is running.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var entered = 0
        var holders: [CheckedContinuation<Void, Never>] = []
        var watchers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Called by the model call: says it has arrived, then waits for `open()`.
    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (isOpen, watchers) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                state.entered += 1
                let watchers = state.watchers
                state.watchers = []
                if !state.isOpen { state.holders.append(continuation) }
                return (state.isOpen, watchers)
            }
            watchers.forEach { $0.resume() }
            if isOpen { continuation.resume() }
        }
    }

    /// Returns once a model call is waiting at the gate.
    func waitUntilEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let entered = state.withLock { state -> Bool in
                if state.entered > 0 { return true }
                state.watchers.append(continuation)
                return false
            }
            if entered { continuation.resume() }
        }
    }

    func open() {
        let holders = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let holders = state.holders
            state.holders = []
            return holders
        }
        holders.forEach { $0.resume() }
    }
}
