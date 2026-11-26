import AppCore
import Foundation

// Fakes for the platform seams in `AppCore/Platform` and `AppCore/Pressure`, so tests never touch the Trash, Finder,
// the pasteboard, IOKit or `UIDevice`.

@MainActor
public final class FakeThermalSource: ThermalSource {
    public var level: ThermalLevel
    private var handler: (@MainActor () -> Void)?

    public init(level: ThermalLevel = .nominal) { self.level = level }

    public func observe(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }

    /// Changes the reading and notifies the observer.
    public func set(_ level: ThermalLevel) {
        self.level = level
        handler?()
    }
}

@MainActor
public final class FakePowerSource: PowerSource {
    public var snapshot: PowerSnapshot
    private var handler: (@MainActor () -> Void)?

    public init(snapshot: PowerSnapshot = .pluggedIn) { self.snapshot = snapshot }

    public func observe(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }

    public func set(_ snapshot: PowerSnapshot) {
        self.snapshot = snapshot
        handler?()
    }
}

@MainActor
public final class FakeActivityStarter: ActivityStarter {
    public private(set) var begun = 0
    public private(set) var ended = 0
    public private(set) var reasons: [String] = []
    public var isHeld: Bool { begun > ended }

    public init() {}

    public func begin(reason: String) -> any ActivityToken {
        begun += 1
        reasons.append(reason)
        return Token(self)
    }

    private final class Token: ActivityToken {
        let owner: FakeActivityStarter
        init(_ owner: FakeActivityStarter) { self.owner = owner }
        func end() { owner.ended += 1 }
    }
}

/// Records what would be trashed; can be told to fail.
public final class FakeFileTrasher: FileTrasher, @unchecked Sendable {
    private let lock = NSLock()
    private var trashedURLs: [URL] = []
    public var failure: (any Error)?

    public init(failure: (any Error)? = nil) { self.failure = failure }

    public var trashed: [URL] { lock.withLock { trashedURLs } }

    public func moveToTrash(_ url: URL) throws -> URL {
        if let failure { throw failure }
        lock.withLock { trashedURLs.append(url) }
        return URL(filePath: "/FakeTrash/" + url.lastPathComponent)
    }
}

@MainActor
public final class FakeFileRevealer: FileRevealer {
    public private(set) var revealed: [[URL]] = []
    public private(set) var opened: [URL] = []

    public init() {}

    public func reveal(_ urls: [URL]) { revealed.append(urls) }
    public func open(_ url: URL) { opened.append(url) }
}

@MainActor
public final class FakePasteboard: Pasteboarding {
    public private(set) var text: String?
    public private(set) var fileURLs: [URL] = []

    public init() {}

    public func copy(text: String) {
        self.text = text
        fileURLs = []
    }

    public func copy(fileURLs: [URL]) {
        self.fileURLs = fileURLs
        text = nil
    }
}

/// A background grant the test can expire.
@MainActor
public final class FakeBackgroundGrant: BackgroundExecutionGrant {
    public private(set) var acquired: [(reason: String, title: String, subtitle: String)] = []
    public private(set) var endedCount = 0
    private var expirations: [@MainActor () -> Void] = []

    public init() {}

    public var isHeld: Bool { acquired.count > endedCount }

    public func acquire(
        reason: String, title: String, subtitle: String, onExpiration: @escaping @MainActor () -> Void
    ) -> any ActivityToken {
        acquired.append((reason, title, subtitle))
        expirations.append(onExpiration)
        return Token(self)
    }

    /// The system takes the grant back.
    public func expire() {
        for handler in expirations { handler() }
    }

    private final class Token: ActivityToken {
        let owner: FakeBackgroundGrant
        init(_ owner: FakeBackgroundGrant) { self.owner = owner }
        func end() { owner.endedCount += 1 }
    }
}

/// A fake continued-processing task handle for testing `BackgroundTaskScheduler` without BackgroundTasks.
public final class FakeContinuedProcessingTask: ContinuedProcessingTask, @unchecked Sendable {
    private let lock = NSLock()
    public let identifier: String
    private var expirationHandler: (@Sendable () -> Void)?
    private var _progressUpdates: [(completed: Int64, total: Int64)] = []
    private var _titleUpdates: [(title: String, subtitle: String)] = []
    private var _completedResults: [Bool] = []

    public init(identifier: String) {
        self.identifier = identifier
    }

    public var hasExpirationHandler: Bool { lock.withLock { expirationHandler != nil } }
    public var progressUpdates: [(completed: Int64, total: Int64)] { lock.withLock { _progressUpdates } }
    public var titleUpdates: [(title: String, subtitle: String)] { lock.withLock { _titleUpdates } }
    public var completedResults: [Bool] { lock.withLock { _completedResults } }

    public func setExpirationHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { expirationHandler = handler }
    }

    public func updateProgress(completedUnitCount: Int64, totalUnitCount: Int64) {
        lock.withLock { _progressUpdates.append((completedUnitCount, totalUnitCount)) }
    }

    public func updateTitle(_ title: String, subtitle: String) {
        lock.withLock { _titleUpdates.append((title, subtitle)) }
    }

    public func setTaskCompleted(success: Bool) {
        lock.withLock {
            _completedResults.append(success)
            expirationHandler = nil
        }
    }

    /// Simulates the system or user expiring the task.
    public func expire() {
        let handler = lock.withLock {
            let current = expirationHandler
            expirationHandler = nil
            return current
        }
        handler?()
    }
}

/// Fake `BackgroundTaskScheduler` for unit testing `ContinuedProcessingCoordinator` and queue expiration.
@MainActor
public final class FakeBackgroundTaskScheduler: BackgroundTaskScheduler {
    public private(set) var registeredIdentifiers: [String] = []
    public private(set) var submittedRequests: [ContinuedProcessingRequest] = []
    public private(set) var cancelledIdentifiers: [String] = []
    public private(set) var tasksByIdentifier: [String: FakeContinuedProcessingTask] = [:]
    public private(set) var launchOrder: [FakeContinuedProcessingTask] = []

    public var submitError: (any Error)?
    public var registerShouldSucceed = true
    public var autoLaunchOnSubmit = true

    private var handlers: [String: @Sendable (any ContinuedProcessingTask) -> Void] = [:]
    private nonisolated let deliveries = DispatchGroup()

    public init() {}

    @discardableResult
    public func register(
        identifier: String,
        handler: @escaping @Sendable (any ContinuedProcessingTask) -> Void
    ) -> Bool {
        registeredIdentifiers.append(identifier)
        guard registerShouldSucceed else { return false }
        handlers[identifier] = handler
        return true
    }

    public func submit(_ request: ContinuedProcessingRequest) throws {
        submittedRequests.append(request)
        if let submitError { throw submitError }
        if autoLaunchOnSubmit {
            launch(identifier: request.identifier)
        }
    }

    public func cancel(identifier: String) {
        cancelledIdentifiers.append(identifier)
    }

    /// Delivers the registered launch handler for `identifier`, returning the fake task handle. Like
    /// `BGTaskScheduler`, the handler runs on a background queue, never on the main actor: a handler closure that is
    /// inferred `@MainActor` traps here exactly as it did on a device. Use `settleLaunches()` to wait for delivery.
    @discardableResult
    public func launch(identifier: String) -> FakeContinuedProcessingTask? {
        guard let handler = handlers[identifier] else { return nil }
        let task = FakeContinuedProcessingTask(identifier: identifier)
        tasksByIdentifier[identifier] = task
        launchOrder.append(task)
        let group = deliveries
        group.enter()
        DispatchQueue.global().async {
            handler(task)
            group.leave()
        }
        return task
    }

    /// Waits until every launch handler dispatched so far has returned, then lets the main actor run the work those
    /// handlers hopped back with.
    public func settleLaunches() async {
        let group = deliveries
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { @Sendable in continuation.resume() }
        }
        for _ in 0..<5 { await Task.yield() }
    }

    /// Fires expiration on the task with `identifier`.
    public func expire(identifier: String) {
        tasksByIdentifier[identifier]?.expire()
    }

    /// Fires expiration on the most recently launched task.
    public func expireLatest() {
        launchOrder.last?.expire()
    }
}
