import Foundation

/// `ProcessInfo.ThermalState`, ordered, so the rules can compare.
public enum ThermalLevel: Int, Comparable, Sendable, CaseIterable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

/// What the power source says now.
public struct PowerSnapshot: Sendable, Equatable {
    /// Running on the battery (not plugged in).
    public var onBattery: Bool
    /// Charge in percent; nil on a Mac without a battery.
    public var percent: Int?

    public init(onBattery: Bool, percent: Int?) {
        self.onBattery = onBattery
        self.percent = percent
    }

    /// A desktop Mac, or a laptop on its charger with no reading.
    public static let pluggedIn = PowerSnapshot(onBattery: false, percent: nil)
}

/// Why the queue paused itself.
public enum AutoPauseReason: Sendable, Equatable {
    case thermal
    case batteryLow
}

/// The automatic decisions: when to pause for heat or a low battery, and how many videos may convert at once. Pure:
/// feed it readings and read the result.
///
/// - Thermal: `.critical` pauses; it resumes only at `.fair` or better, so `.serious` on the way down stays paused.
///   `.serious` alone (not paused) limits conversion to one video at a time.
/// - Battery: conversion continues on battery. It pauses at 20 % or less, and resumes when the Mac is plugged in or
///   above 25 %. A Mac that reports no percentage never pauses.
public struct PressureState: Sendable, Equatable {
    public static let batteryPausePercent = 20
    public static let batteryResumePercent = 25

    public private(set) var thermal = ThermalLevel.nominal
    public private(set) var power = PowerSnapshot.pluggedIn
    public var speed: SpeedSetting
    private var isHotPaused = false
    private var isBatteryPaused = false

    public init(speed: SpeedSetting = .default) {
        self.speed = speed
    }

    public mutating func update(thermal level: ThermalLevel) {
        thermal = level
        if level == .critical {
            isHotPaused = true
        } else if level <= .fair {
            isHotPaused = false
        }
    }

    public mutating func update(power snapshot: PowerSnapshot) {
        power = snapshot
        guard snapshot.onBattery, let percent = snapshot.percent else {
            isBatteryPaused = false
            return
        }
        if percent <= Self.batteryPausePercent {
            isBatteryPaused = true
        } else if percent > Self.batteryResumePercent {
            isBatteryPaused = false
        }
    }

    /// Why the queue should be paused now; heat before battery.
    public var automaticPause: AutoPauseReason? {
        if isHotPaused { return .thermal }
        if isBatteryPaused { return .batteryLow }
        return nil
    }

    /// How many downscales may run at once: the speed's number, and one at most while the Mac is hot.
    public func concurrencyLimit(cores: CoreCounts) -> Int {
        if thermal >= .serious { return 1 }
        switch speed {
        case .quiet: return 1
        case .balanced: return max(2, cores.active / 2)
        case .fastest: return max(1, cores.performance)
        }
    }

    /// What the rest of the app acts on.
    public func effect(cores: CoreCounts) -> PressureEffect {
        PressureEffect(
            automaticPause: automaticPause, concurrencyLimit: concurrencyLimit(cores: cores),
            runsInBackground: speed.runsInBackground)
    }
}

/// The result of `PressureState`: all the app needs to apply.
public struct PressureEffect: Sendable, Equatable {
    public var automaticPause: AutoPauseReason?
    public var concurrencyLimit: Int
    public var runsInBackground: Bool
}

/// Why the queue is paused, for the status line. A pause the user chose wins over an automatic one: an automatic
/// resume never overrides it, and pressing Resume then shows the automatic reason if it still applies.
public struct QueuePause: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case user
        case automatic(AutoPauseReason)
    }

    public var isPausedByUser: Bool
    public var automatic: AutoPauseReason?

    public init(isPausedByUser: Bool, automatic: AutoPauseReason?) {
        self.isPausedByUser = isPausedByUser
        self.automatic = automatic
    }

    public var isPaused: Bool { isPausedByUser || automatic != nil }

    public var reason: Reason? {
        if isPausedByUser { return .user }
        return automatic.map(Reason.automatic)
    }

    /// The sentence for the queue's status line; nil when running.
    public var statusText: String? {
        switch reason {
        case nil: nil
        case .user: "Paused"
        case .automatic(.thermal): "Paused while your Mac cools down"
        case .automatic(.batteryLow): "Paused: battery low"
        }
    }
}
