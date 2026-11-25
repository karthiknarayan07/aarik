import Foundation
import IOKit.ps

// The system inputs behind small protocols, so the decisions are tested with fakes. Each source says what it reads
// now and calls the handler (on the main actor) after every change; the handler reads again.

/// The Mac's thermal state.
@MainActor
public protocol ThermalSource: AnyObject {
    var level: ThermalLevel { get }
    func observe(_ handler: @escaping @MainActor () -> Void)
}

/// Battery or charger, and the charge.
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

/// IOPowerSources: on battery or not, and the internal battery's charge. Changes arrive on the main run loop.
@MainActor
public final class SystemPowerSource: PowerSource {
    private var handler: (@MainActor () -> Void)?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    public var snapshot: PowerSnapshot { Self.read() }

    public func observe(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<SystemPowerSource>.fromOpaque(context).takeUnretainedValue().handler?()
                }
            }, context
        )?.takeRetainedValue()
        guard let source else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    private static func read() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .pluggedIn }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPSBatteryPowerValue
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerSnapshot(onBattery: onBattery, percent: nil)
        }
        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return PowerSnapshot(onBattery: onBattery, percent: min(100, max(0, current * 100 / maximum)))
        }
        return PowerSnapshot(onBattery: onBattery, percent: nil)
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
