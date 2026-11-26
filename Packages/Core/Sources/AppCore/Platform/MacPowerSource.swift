#if os(macOS)
    import Foundation
    import IOKit.ps

    /// IOPowerSources: on battery or not, and the internal battery's charge, plus Low Power Mode from `ProcessInfo`.
    /// Changes arrive on the main run loop and as `NSProcessInfoPowerStateDidChange`.
    @MainActor
    public final class SystemPowerSource: PowerSource {
        private var handler: (@MainActor () -> Void)?
        private var runLoopSource: CFRunLoopSource?
        private var lowPowerObserver: (any NSObjectProtocol)?

        public init() {}

        public var snapshot: PowerSnapshot { Self.read() }

        public func observe(_ handler: @escaping @MainActor () -> Void) {
            self.handler = handler
            if lowPowerObserver == nil {
                lowPowerObserver = NotificationCenter.default.addObserver(
                    forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handler?() }
                }
            }
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
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        private static func read() -> PowerSnapshot {
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                return PowerSnapshot(onBattery: false, percent: nil, isLowPowerMode: lowPower)
            }
            let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            let onBattery = providing == kIOPSBatteryPowerValue
            guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
                return PowerSnapshot(onBattery: onBattery, percent: nil, isLowPowerMode: lowPower)
            }
            for source in list {
                guard
                    let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                        as? [String: Any],
                    description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                    let current = description[kIOPSCurrentCapacityKey] as? Int,
                    let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
                else { continue }
                return PowerSnapshot(
                    onBattery: onBattery, percent: min(100, max(0, current * 100 / maximum)),
                    isLowPowerMode: lowPower)
            }
            return PowerSnapshot(onBattery: onBattery, percent: nil, isLowPowerMode: lowPower)
        }
    }
#endif
