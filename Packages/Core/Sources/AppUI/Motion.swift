import SwiftUI

/// What Reduce Motion changes: every small animation in the app goes through here, so one rule decides it. With
/// Reduce Motion on, values change in place without animating and the symbol bounce never fires.
public enum Motion {
    /// `animation` normally; none when Reduce Motion is on.
    public static func animation(_ animation: Animation = .smooth, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// The value a one-shot symbol effect watches. It changes (and so bounces) whenever `value` does; with Reduce
    /// Motion on it stays 0 and nothing bounces.
    public static func bounceTrigger(_ value: Int?, reduceMotion: Bool) -> Int {
        reduceMotion ? 0 : (value ?? 0)
    }
}
