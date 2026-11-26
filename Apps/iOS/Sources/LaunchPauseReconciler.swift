import Foundation

/// Decides the queue's pause state at launch.
///
/// The Control Center control flips the shared App Group flag even while the app isn't running. The app mirrors its
/// own pause state into that flag, so a flag that differs from the last value the app wrote was changed by the
/// control, and the flag wins. A flag equal to the last value written is the app's own old state, so the app's value
/// (the "start the queue automatically" setting) stands. With no recorded write the flag is not ours: it wins.
struct LaunchPauseReconciler {
    static let lastWrittenKey = "sharedPauseLastWritten"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The pause state to start with, given the app's own value and the shared flag (nil when none is stored).
    func resolve(appPaused: Bool, shared: Bool?) -> Bool {
        guard let shared else { return appPaused }
        guard let lastWritten = defaults.object(forKey: Self.lastWrittenKey) as? Bool else { return shared }
        return shared == lastWritten ? appPaused : shared
    }

    /// Records the value the app just mirrored into the shared flag.
    func recordWritten(_ isPaused: Bool) {
        defaults.set(isPaused, forKey: Self.lastWrittenKey)
    }
}
