import Foundation

/// Permission to keep working while the app is not in front. The Mac's grant is `beginActivity` (the app keeps running
/// anyway, so it only stops App Nap and idle sleep). iOS needs `BGContinuedProcessingTask` and can lose the grant at
/// any time, so a holder must handle `onExpiration`.
@MainActor
public protocol BackgroundExecutionGrant: AnyObject {
    /// Asks for background time. `title` and `subtitle` are what iOS shows in its Live Activity. The token ends it.
    func acquire(
        reason: String, title: String, subtitle: String, onExpiration: @escaping @MainActor () -> Void
    ) -> any ActivityToken
}

/// The Mac adapter: `beginActivity` through `ActivityStarter`. It never expires.
@MainActor
public final class ActivityBackgroundGrant: BackgroundExecutionGrant {
    private let starter: any ActivityStarter

    public init(starter: any ActivityStarter = SystemActivityStarter()) { self.starter = starter }

    public func acquire(
        reason: String, title: String, subtitle: String, onExpiration: @escaping @MainActor () -> Void
    ) -> any ActivityToken {
        starter.begin(reason: reason)
    }
}
