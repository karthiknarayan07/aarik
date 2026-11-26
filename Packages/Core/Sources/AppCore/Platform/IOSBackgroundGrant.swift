#if os(iOS)
    import Foundation

    /// The iOS adapter, as a stub. Task 7 replaces the body with a `BGContinuedProcessingTask` submission and
    /// calls `onExpiration` from the task's expiration handler. Until then it holds `beginActivity`, which only
    /// affects throttling while the app is running and does not keep a suspended app alive.
    @MainActor
    public final class ContinuedProcessingGrant: BackgroundExecutionGrant {
        private let starter: any ActivityStarter

        public init(starter: any ActivityStarter = SystemActivityStarter()) { self.starter = starter }

        public func acquire(
            reason: String, title: String, subtitle: String, onExpiration: @escaping @MainActor () -> Void
        ) -> any ActivityToken {
            starter.begin(reason: reason)
        }
    }
#endif
