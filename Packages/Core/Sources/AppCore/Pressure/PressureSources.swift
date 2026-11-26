import Foundation

// The system inputs behind small protocols, so the decisions are tested with fakes. Each source says what it reads
// now and calls the handler (on the main actor) after every change; the handler reads again.

/// The Mac's thermal state.
@MainActor
public protocol ThermalSource: AnyObject {
    var level: ThermalLevel { get }
    func observe(_ handler: @escaping @MainActor () -> Void)
}

/// Battery or charger, the charge and Low Power Mode (`PowerSnapshot.isLowPowerMode`).
@MainActor
public protocol PowerSource: AnyObject {
    var snapshot: PowerSnapshot { get }
    func observe(_ handler: @escaping @MainActor () -> Void)
}

/// Keeps the Mac awake while held (`ProcessInfo.beginActivity`).
@MainActor
public protocol ActivityStarter: AnyObject {
    func begin(reason: String) -> any ActivityToken
}

@MainActor
public protocol ActivityToken: AnyObject {
    func end()
}

// MARK: - The real ones (they live as long as the app)

@MainActor
public final class SystemThermalSource: ThermalSource {
    private var observer: (any NSObjectProtocol)?

    public init() {}

    public var level: ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }

    public func observe(_ handler: @escaping @MainActor () -> Void) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}

/// The display may sleep; the system may not.
@MainActor
public final class SystemActivityStarter: ActivityStarter {
    public init() {}

    public func begin(reason: String) -> any ActivityToken {
        Token(
            ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: reason))
    }

    private final class Token: ActivityToken {
        private var activity: (any NSObjectProtocol)?

        init(_ activity: any NSObjectProtocol) { self.activity = activity }

        func end() {
            guard let activity else { return }
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
