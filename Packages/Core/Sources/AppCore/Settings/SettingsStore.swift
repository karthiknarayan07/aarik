import Foundation

/// The settings every tool shares, stored in `UserDefaults`. A tool keeps its own settings (its preset, where it saves)
/// under its own keys. The Settings views bind these keys with `@AppStorage`; the services read the same ones.
///
/// The key strings are stored on every user's Mac: they never change.
public struct SettingsStore: @unchecked Sendable {
    public enum Keys {
        /// Whether adding to the queue starts it.
        public static let autoStartQueue = "queue.autoStart"
        /// `SpeedSetting` raw value: quiet, balanced or fastest.
        public static let speed = "performance.speed"
    }

    // `UserDefaults` is documented as thread-safe but isn't marked `Sendable`.
    public let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// On unless turned off.
    public var autoStartQueue: Bool {
        defaults.object(forKey: Keys.autoStartQueue) as? Bool ?? true
    }

    /// Balanced unless the user chose another speed.
    public var speed: SpeedSetting {
        get { defaults.string(forKey: Keys.speed).flatMap(SpeedSetting.init(rawValue:)) ?? .default }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.speed) }
    }
}
