import Foundation
import Synchronization

/// How long a conversion may go without any progress before it is failed ("The encoder stopped responding").
/// A stalled `AVAssetWriter` (it stops asking for data, with no error) would otherwise leave a job at the same
/// percentage for ever, holding its `WorkSlots` slot. Tests pass tiny limits; the app uses `standard`.
public struct StallLimits: Sendable, Equatable {
    /// In the loops that feed the writer: no sample read, appended or accepted for this long.
    public var noProgress: Duration
    /// `finishWriting` that doesn't call back for this long: the writer is cancelled.
    public var finish: Duration
    /// A call that can't be interrupted (`copyNextSampleBuffer`, `completeFrames`) that doesn't return for this long:
    /// the watchdog outside the job gives up on it. Longer than `noProgress`, so the loops report first when they can.
    public var blockedCall: Duration
    /// How often the outside watchdog looks.
    public var poll: Duration

    public init(
        noProgress: Duration = .seconds(60), finish: Duration = .seconds(60), blockedCall: Duration = .seconds(90),
        poll: Duration = .seconds(1)
    ) {
        self.noProgress = noProgress
        self.finish = finish
        self.blockedCall = blockedCall
        self.poll = poll
    }

    public static let standard = StallLimits()
}

/// Where a test can force a stall (`VideoDownscaler.forceStall`).
enum StallPoint: Sendable {
    /// The video input never takes another sample.
    case videoInput
    /// The passthrough tracks never take another sample while the tail is drained.
    case drain
    /// `finishWriting` never calls back.
    case finish
    /// An uninterruptible call that doesn't return while this is true.
    case blockingCall
}

/// When a job last made progress, readable from the watchdog outside it, plus how to stop the job from there.
final class Heartbeat: Sendable {
    private struct State {
        var last = ContinuousClock.now
        var partial: URL?
        var abort: (@Sendable () -> Void)?
        var stalled = false
    }
    private let state = Mutex(State())

    func beat() { state.withLock { $0.last = .now } }

    var idle: Duration { state.withLock { ContinuousClock.now - $0.last } }

    var hasStalled: Bool { state.withLock { $0.stalled } }

    func register(partial: URL, abort: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.partial = partial
            $0.abort = abort
        }
    }

    /// The watchdog gave up: stops reading and writing and removes the partial file (the job, if it ever gets going
    /// again, finds `hasStalled` set and doesn't commit anything).
    func giveUp() {
        let (partial, abort) = state.withLock { state -> (URL?, (@Sendable () -> Void)?) in
            state.stalled = true
            return (state.partial, state.abort)
        }
        abort?()
        if let partial { try? FileManager.default.removeItem(at: partial) }
    }
}

/// Runs `work` and, from outside it, fails the run with `DownscaleError.stalled` when its heartbeat stops for
/// `limits.blockedCall`. This is what frees the caller (and so the `WorkSlots` slot) when the job is stuck in a call
/// that can't be interrupted: the stuck task is abandoned, and ends whenever that call returns.
enum StallWatchdog {
    private final class Gate<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, any Error>?
            var done = false
            var cancelled = false
            var tasks: [Task<Void, Never>] = []
        }
        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            state.withLock { $0.continuation = continuation }
        }

        func add(_ task: Task<Void, Never>) {
            let cancelNow = state.withLock { state -> Bool in
                state.tasks.append(task)
                return state.cancelled || state.done
            }
            if cancelNow { task.cancel() }
        }

        /// The first call decides the result.
        func finish(_ result: Result<T, any Error>) {
            typealias Taken = (CheckedContinuation<T, any Error>?, [Task<Void, Never>])
            let (continuation, tasks) = state.withLock { state -> Taken in
                guard !state.done else { return (nil, []) }
                state.done = true
                defer { state.continuation = nil }
                return (state.continuation, state.tasks)
            }
            continuation?.resume(with: result)
            for task in tasks { task.cancel() }
        }

        func cancel() {
            let tasks = state.withLock { state -> [Task<Void, Never>] in
                state.cancelled = true
                return state.tasks
            }
            for task in tasks { task.cancel() }
        }
    }

    static func race<T: Sendable>(
        heartbeat: Heartbeat, limits: StallLimits, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                gate.install(continuation)
                gate.add(
                    Task {
                        do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) }
                    })
                gate.add(
                    Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: limits.poll)
                            if Task.isCancelled { return }
                            if heartbeat.idle > limits.blockedCall {
                                heartbeat.giveUp()
                                gate.finish(.failure(DownscaleError.stalled))
                                return
                            }
                        }
                    })
            }
        } onCancel: {
            gate.cancel()
        }
    }
}
