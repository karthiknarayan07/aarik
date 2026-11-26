import Foundation

/// Submission strategy for a continued-processing background task, mirroring
/// `BGContinuedProcessingTaskRequest.SubmissionStrategy`.
public enum ContinuedProcessingSubmissionStrategy: Sendable, Equatable {
    case fail
    case queue
}

/// Parameters for requesting continued background execution, mirroring `BGContinuedProcessingTaskRequest`.
public struct ContinuedProcessingRequest: Sendable, Equatable {
    public let identifier: String
    public var title: String
    public var subtitle: String
    public var strategy: ContinuedProcessingSubmissionStrategy

    public init(
        identifier: String,
        title: String,
        subtitle: String,
        strategy: ContinuedProcessingSubmissionStrategy = .fail
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.strategy = strategy
    }
}

/// Abstracts a running `BGContinuedProcessingTask` so background execution can be tested without BackgroundTasks.
public protocol ContinuedProcessingTask: AnyObject, Sendable {
    var identifier: String { get }
    func setExpirationHandler(_ handler: (@Sendable () -> Void)?)
    func updateProgress(completedUnitCount: Int64, totalUnitCount: Int64)
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

/// Protocol seam over `BGTaskScheduler` for continued-processing task registration, submission, and cancellation.
@MainActor
public protocol BackgroundTaskScheduler: AnyObject {
    /// Registers a launch handler for `identifier`. Each concrete identifier must be registered at most once.
    @discardableResult
    func register(
        identifier: String,
        handler: @escaping @Sendable (any ContinuedProcessingTask) -> Void
    ) -> Bool

    /// Submits a continued-processing request for immediate or queued execution.
    func submit(_ request: ContinuedProcessingRequest) throws

    /// Cancels a pending request whose task has not yet launched.
    func cancel(identifier: String)
}

/// Coordinates a single `BGContinuedProcessingTask` across a queue run: submits once per run, forwards current-item
/// progress and title updates, ends the task when the run stops, and cancels + re-queues work on expiration.
@MainActor
public final class ContinuedProcessingCoordinator {
    private static let totalUnits: Int64 = 1000

    private let scheduler: any BackgroundTaskScheduler
    private let identifierPrefix: String
    private let strategy: ContinuedProcessingSubmissionStrategy
    private let onExpire: @MainActor () async -> Void
    private let onSubmitFailure: (@MainActor (any Error) -> Void)?

    private var currentIdentifier: String?
    private var activeTask: (any ContinuedProcessingTask)?
    private var expiredIdentifiers: Set<String> = []
    private var hasAttemptedRun = false
    private var isExpiring = false
    private var isFinished = false

    private var latestTitle = ""
    private var latestSubtitle = ""
    private var latestCompletedUnits: Int64 = 0
    private var pushedTitle: String?
    private var pushedSubtitle: String?
    private var pushedCompletedUnits: Int64?

    public private(set) var expirationTask: Task<Void, Never>?

    public init(
        scheduler: any BackgroundTaskScheduler,
        identifierPrefix: String,
        strategy: ContinuedProcessingSubmissionStrategy = .fail,
        onExpire: @escaping @MainActor () async -> Void,
        onSubmitFailure: (@MainActor (any Error) -> Void)? = nil
    ) {
        self.scheduler = scheduler
        self.identifierPrefix = identifierPrefix
        self.strategy = strategy
        self.onExpire = onExpire
        self.onSubmitFailure = onSubmitFailure
    }

    public var isActive: Bool { currentIdentifier != nil }

    /// Synchronizes the background task with whether work is currently under way, showing current-item details.
    public func update(isRunning: Bool, title: String, subtitle: String, progress: Double) {
        if !isRunning {
            hasAttemptedRun = false
            endActiveTask(success: true)
            return
        }
        guard !isExpiring else { return }

        let units = Int64((min(max(progress, 0), 1) * Double(Self.totalUnits)).rounded())
        latestTitle = title
        latestSubtitle = subtitle
        latestCompletedUnits = units

        if currentIdentifier == nil {
            guard !hasAttemptedRun else { return }
            hasAttemptedRun = true
            startTask(title: title, subtitle: subtitle)
        } else if let activeTask {
            pushUpdates(to: activeTask)
        }
    }

    private func startTask(title: String, subtitle: String) {
        let identifier = "\(identifierPrefix).\(UUID().uuidString)"
        currentIdentifier = identifier
        isFinished = false
        pushedTitle = nil
        pushedSubtitle = nil
        pushedCompletedUnits = nil

        let registered = scheduler.register(identifier: identifier) { @Sendable [weak self] task in
            // Attach the expiration handler synchronously before returning so the system never sees a task without one.
            task.setExpirationHandler { @Sendable [weak self] in
                Task { @MainActor in
                    self?.handleExpiration(for: identifier, task: task)
                }
            }
            Task { @MainActor in
                self?.attachTask(task, for: identifier)
            }
        }
        guard registered else {
            currentIdentifier = nil
            return
        }

        do {
            try scheduler.submit(
                ContinuedProcessingRequest(
                    identifier: identifier,
                    title: title,
                    subtitle: subtitle,
                    strategy: strategy
                )
            )
        } catch {
            currentIdentifier = nil
            activeTask = nil
            isFinished = true
            onSubmitFailure?(error)
        }
    }

    private func attachTask(_ task: any ContinuedProcessingTask, for identifier: String) {
        guard !expiredIdentifiers.contains(identifier) else { return }
        guard currentIdentifier == identifier, !isFinished else {
            task.setTaskCompleted(success: true)
            return
        }
        activeTask = task
        pushUpdates(to: task)
    }

    private func pushUpdates(to task: any ContinuedProcessingTask) {
        if pushedTitle != latestTitle || pushedSubtitle != latestSubtitle {
            task.updateTitle(latestTitle, subtitle: latestSubtitle)
            pushedTitle = latestTitle
            pushedSubtitle = latestSubtitle
        }
        if pushedCompletedUnits != latestCompletedUnits {
            task.updateProgress(completedUnitCount: latestCompletedUnits, totalUnitCount: Self.totalUnits)
            pushedCompletedUnits = latestCompletedUnits
        }
    }

    private func endActiveTask(success: Bool) {
        guard let identifier = currentIdentifier else { return }
        isFinished = true
        currentIdentifier = nil
        if let task = activeTask {
            activeTask = nil
            task.setTaskCompleted(success: success)
        } else {
            scheduler.cancel(identifier: identifier)
        }
    }

    private func handleExpiration(for identifier: String, task: any ContinuedProcessingTask) {
        guard expiredIdentifiers.insert(identifier).inserted else { return }
        guard currentIdentifier == identifier || activeTask?.identifier == identifier else {
            task.setTaskCompleted(success: false)
            return
        }
        isExpiring = true
        isFinished = true
        let expiringTask = activeTask ?? task
        activeTask = nil
        currentIdentifier = nil

        expirationTask = Task { @MainActor in
            await onExpire()
            expiringTask.setTaskCompleted(success: false)
            self.isExpiring = false
        }
    }
}
