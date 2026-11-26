import Foundation

/// The settings every tool shares, stored in `UserDefaults`. A tool keeps its own settings (its preset, where it saves)
/// under its own keys. The Settings views bind these keys with `@AppStorage`; the services read the same ones.
///
/// The key strings are stored on every user's Mac: they never change.
public struct SettingsStore: @unchecked Sendable {
    public enum Keys {
        /// Whether adding to the queue starts it.
        public static let autoStartQueue = "queue.autoStart"
        /// Whether the user started a run that hasn't finished: only a run in progress comes back after a relaunch
        /// when auto-start is off.
        public static let runActive = "queue.runActive"
        /// `SpeedSetting` raw value: quiet, balanced or fastest.
        public static let speed = "performance.speed"
    }

    // `UserDefaults` is documented as thread-safe but isn't marked `Sendable`.
    public let defaults: UserDefaults
    private let autoStartDefault: Bool

    /// What adding to the queue does when the user never chose: the Mac starts the run, iOS waits for Start (a run
    /// there holds a Live Activity and background time, so the user starts it on purpose).
    public static let platformAutoStartDefault: Bool = {
        #if os(iOS)
            false
        #else
            true
        #endif
    }()

    public init(_ defaults: UserDefaults = .standard, autoStartDefault: Bool = platformAutoStartDefault) {
        self.defaults = defaults
        self.autoStartDefault = autoStartDefault
    }

    /// The platform's default (on for the Mac, off for iOS) unless the user chose.
    public var autoStartQueue: Bool {
        defaults.object(forKey: Keys.autoStartQueue) as? Bool ?? autoStartDefault
    }

    /// Whether a run the user started was still going when the app last ran.
    public var runActive: Bool {
        get { defaults.bool(forKey: Keys.runActive) }
        nonmutating set { defaults.set(newValue, forKey: Keys.runActive) }
    }

    /// Balanced unless the user chose another speed.
    public var speed: SpeedSetting {
        get { defaults.string(forKey: Keys.speed).flatMap(SpeedSetting.init(rawValue:)) ?? .default }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.speed) }
    }
}
