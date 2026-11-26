import Foundation

/// How hard the Settings window lets a conversion work. The thermal rules (`PressureState`) apply on top.
public enum SpeedSetting: String, CaseIterable, Codable, Sendable, Identifiable {
    /// One video at a time at background priority: the least heat and fan noise.
    case quiet
    /// Half the cores, at least two.
    case balanced
    /// Every performance core.
    case fastest

    public static let `default` = SpeedSetting.balanced

    public var id: String { rawValue }

    /// The label of the radio button (Title Case).
    public var title: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .fastest: "Fastest"
        }
    }

    /// One sentence under the option (sentence case).
    public var summary: String {
        switch self {
        case .quiet: "One video at a time at low priority: easiest on heat, fan noise and other apps."
        case .balanced:
            "Converts several videos at once, using about half of your Mac's cores, and leaves room for other apps."
        case .fastest:
            "Converts as many videos at once as your Mac's performance cores allow. Your Mac may get warm and its fans louder."
        }
    }

    /// Whether the encoder's threads run at background priority.
    public var runsInBackground: Bool { self == .quiet }
}

/// How many cores this Mac has.
public struct CoreCounts: Sendable, Equatable {
    /// Cores that are on now.
    public var active: Int
    /// Performance cores (all cores on a Mac without efficiency cores).
    public var performance: Int

    public init(active: Int, performance: Int) {
        self.active = max(1, active)
        self.performance = max(1, performance)
    }
}

/// Where the core counts come from; a fake in tests.
public protocol CoreCounting: Sendable {
    var counts: CoreCounts { get }
}

public struct SystemCoreCounts: CoreCounting {
    public init() {}

    public var counts: CoreCounts {
        let active = ProcessInfo.processInfo.activeProcessorCount
        return CoreCounts(active: active, performance: Self.performanceCores() ?? active)
    }

    /// `hw.perflevel0` is the highest performance level: the performance cores on Apple silicon.
    private static func performanceCores() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}
