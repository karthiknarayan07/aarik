import AppCore

/// Holds a staged hand-off (videos from the share extension or an intent) until the app can show it. The route is
/// handed out once, and only when the onboarding is done and the restored tab and stack are in place, so a cold
/// launch or the introduction never loses it or is interrupted by it.
struct HandoffGate: Equatable {
    private(set) var pending: ToolRoute?

    /// A newer hand-off replaces one that has not been shown yet.
    mutating func stage(_ route: ToolRoute) { pending = route }

    /// The route to open now, or nil while it must keep waiting (or when nothing is staged).
    mutating func take(hasOnboarded: Bool, hasRestored: Bool) -> ToolRoute? {
        guard hasOnboarded, hasRestored, let route = pending else { return nil }
        pending = nil
        return route
    }
}
