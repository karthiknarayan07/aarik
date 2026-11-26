#if os(iOS)
    import BackgroundTasks
    import Foundation

    /// Wraps `BGContinuedProcessingTask` behind `ContinuedProcessingTask`.
    private final class SystemContinuedProcessingTask: ContinuedProcessingTask, @unchecked Sendable {
        private let task: BGContinuedProcessingTask

        init(_ task: BGContinuedProcessingTask) {
            self.task = task
        }

        var identifier: String { task.identifier }

        func setExpirationHandler(_ handler: (@Sendable () -> Void)?) {
            task.expirationHandler = handler
        }

        func updateProgress(completedUnitCount: Int64, totalUnitCount: Int64) {
            task.progress.totalUnitCount = totalUnitCount
            task.progress.completedUnitCount = completedUnitCount
        }

        func updateTitle(_ title: String, subtitle: String) {
            task.updateTitle(title, subtitle: subtitle)
        }

        func setTaskCompleted(success: Bool) {
            task.setTaskCompleted(success: success)
        }
    }

    /// Production `BackgroundTaskScheduler` backed by `BGTaskScheduler.shared`.
    @MainActor
    public final class SystemBackgroundTaskScheduler: BackgroundTaskScheduler {
        public static let shared = SystemBackgroundTaskScheduler()

        private var registeredIdentifiers: Set<String> = []

        public init() {}

        @discardableResult
        public func register(
            identifier: String,
            handler: @escaping @Sendable (any ContinuedProcessingTask) -> Void
        ) -> Bool {
            guard registeredIdentifiers.insert(identifier).inserted else { return true }
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                handler(SystemContinuedProcessingTask(continued))
            }
            if !ok { registeredIdentifiers.remove(identifier) }
            return ok
        }

        public func submit(_ request: ContinuedProcessingRequest) throws {
            let bgRequest = BGContinuedProcessingTaskRequest(
                identifier: request.identifier, title: request.title, subtitle: request.subtitle)
            bgRequest.strategy =
                switch request.strategy {
                case .fail: .fail
                case .queue: .queue
                }
            bgRequest.requiredResources = []
            try BGTaskScheduler.shared.submit(bgRequest)
        }

        public func cancel(identifier: String) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    /// The iOS adapter: submits a `BGContinuedProcessingTaskRequest` through `BackgroundTaskScheduler` and holds a
    /// `ProcessInfo` activity for foreground throttling. Calls `onExpiration` when the system or user stops the task.
    @MainActor
    public final class ContinuedProcessingGrant: BackgroundExecutionGrant {
        private let starter: any ActivityStarter
        private let scheduler: any BackgroundTaskScheduler
        private let identifierPrefix: String

        public init(
            starter: any ActivityStarter = SystemActivityStarter(),
            scheduler: (any BackgroundTaskScheduler)? = nil,
            identifierPrefix: String? = nil
        ) {
            self.starter = starter
            self.scheduler = scheduler ?? SystemBackgroundTaskScheduler.shared
            let bundleID = Bundle.main.bundleIdentifier ?? "app"
            self.identifierPrefix = identifierPrefix ?? "\(bundleID).convert"
        }

        public func acquire(
            reason: String, title: String, subtitle: String, onExpiration: @escaping @MainActor () -> Void
        ) -> any ActivityToken {
            let activity = starter.begin(reason: reason)
            let coordinator = ContinuedProcessingCoordinator(
                scheduler: scheduler,
                identifierPrefix: identifierPrefix,
                onExpire: { onExpiration() }
            )
            coordinator.update(isRunning: true, title: title, subtitle: subtitle, progress: 0)
            return GrantToken(activity: activity, coordinator: coordinator)
        }

        @MainActor
        private final class GrantToken: ActivityToken {
            private let activity: any ActivityToken
            private let coordinator: ContinuedProcessingCoordinator

            init(activity: any ActivityToken, coordinator: ContinuedProcessingCoordinator) {
                self.activity = activity
                self.coordinator = coordinator
            }

            func end() {
                coordinator.update(isRunning: false, title: "", subtitle: "", progress: 0)
                activity.end()
            }
        }
    }
#endif
