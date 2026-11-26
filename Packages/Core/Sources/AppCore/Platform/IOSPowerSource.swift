#if os(iOS)
    import Foundation
    import UIKit

    /// `UIDevice` battery state and level, and Low Power Mode from `ProcessInfo`. Battery monitoring is off by
    /// default, so it is switched on here; until then `batteryState` is `.unknown`, which reads as plugged in.
    @MainActor
    public final class SystemPowerSource: PowerSource {
        private var handler: (@MainActor () -> Void)?
        private var observers: [any NSObjectProtocol] = []

        public init() {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }

        public var snapshot: PowerSnapshot {
            let device = UIDevice.current
            let onBattery = device.batteryState == .unplugged
            let level = device.batteryLevel
            let percent = level >= 0 ? min(100, max(0, Int((level * 100).rounded()))) : nil
            return PowerSnapshot(
                onBattery: onBattery, percent: percent, isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }

        public func observe(_ handler: @escaping @MainActor () -> Void) {
            self.handler = handler
            guard observers.isEmpty else { return }
            let names: [Notification.Name] = [
                UIDevice.batteryStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification,
                .NSProcessInfoPowerStateDidChange,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handler?() }
                }
            }
        }
    }
#endif
