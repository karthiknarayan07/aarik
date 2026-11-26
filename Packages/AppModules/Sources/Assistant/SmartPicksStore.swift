import DownscaleVideo
import Foundation
import Observation

/// Time as the picks store reads it: how long since some fixed moment, and how to wait. The app uses the real
/// clock; a test hands in one it moves by hand, so debounce and retry timing never depend on real sleeping.
public struct SmartPicksClock: Sendable {
    public var now: @Sendable () -> Duration
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    /// The system's continuous clock, counted from the moment this is made.
    public static var continuous: SmartPicksClock {
        let clock = ContinuousClock()
        let origin = clock.now
        return SmartPicksClock(now: { origin.duration(to: clock.now) }, sleep: { try await clock.sleep(for: $0) })
    }
}

/// The Overview's groups of videos and, when the model is available, its picks among them.
///
/// The groups are plain Swift and always there. Picks are asked for when the Overview is showing and kept:
///
/// - Picks already shown stay on screen while the groups change. They are followed by the group's identity
///   (quality, year, library), take its new numbers, and a pick whose group is gone disappears at once.
/// - A new answer is asked for in the background, after the groups have been quiet for `debounce` (or at most
///   `maximumStaleness` after the first change while they keep changing, such as while the queue runs), and
///   replaces the list in one step. A failed refresh keeps the picks shown.
/// - A failed answer is kept, so a refusing model isn't asked over and over: after any fallback the model is
///   not asked again before `retryAfter`, however the groups change, and it is tried again once that has
///   passed. A cancelled request changes nothing.
@MainActor
@Observable
public final class SmartPicksStore {
    public enum State: Sendable, Equatable {
        /// Nothing to show yet, or a request was cancelled.
        case idle
        /// The first request is running; a spinner stands in.
        case loading
        case picks([SmartPick])
        /// The model gave no usable answer: the view lists the biggest groups.
        case fallback
    }

    public let availability: AssistantAvailability
    public private(set) var state = State.idle
    /// Every group that could free something, the biggest first.
    public private(set) var buckets: [SavingsBucket] = []
    /// Videos that could free something but are in no group because they have no capture date.
    public private(set) var undatedCount = 0
    /// Changes whenever the groups are replaced; a view uses it to know when to run `generateIfNeeded` again.
    public private(set) var revision = 0

    @ObservationIgnored private let picker: SmartPicker
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let maximumStaleness: Duration
    @ObservationIgnored private let retryAfter: Duration
    @ObservationIgnored private let clock: SmartPicksClock
    @ObservationIgnored private var key: AnyHashable?
    @ObservationIgnored private var run = 0
    /// The shown picks (or fallback) are for older groups than `buckets`.
    @ObservationIgnored private var isStale = false
    @ObservationIgnored private var staleSince: Duration?
    /// When the model last gave no usable answer; nil after a good one.
    @ObservationIgnored private var failedAt: Duration?

    /// Test seam: how many times the model was asked.
    @ObservationIgnored public private(set) var requests = 0

    public init(
        availability: AssistantAvailability, picker: SmartPicker, debounce: Duration = .seconds(5),
        maximumStaleness: Duration = .seconds(60), retryAfter: Duration = .seconds(300),
        clock: SmartPicksClock = .continuous
    ) {
        self.clock = clock
        self.availability = availability
        self.picker = picker
        self.debounce = debounce
        self.maximumStaleness = maximumStaleness
        self.retryAfter = retryAfter
    }

    /// Whether any AI wording may be shown: the model is available and has not failed for these groups.
    public var isShowingPicks: Bool {
        guard availability.isAvailable else { return false }
        switch state {
        case .idle, .loading, .picks: return true
        case .fallback: return false
        }
    }

    /// The group as it is now, for acting on a row: nil when it is gone.
    public func current(_ bucket: SavingsBucket) -> SavingsBucket? {
        buckets.first { $0.identity == bucket.identity }
    }

    /// Replaces the groups. When `key` is the same as last time nothing changes. Otherwise the picks shown are
    /// kept, brought up to date and marked for a refresh, never cleared to a spinner.
    public func update(buckets: [SavingsBucket], undatedCount: Int = 0, key: some Hashable) {
        let key = AnyHashable(key)
        guard key != self.key else { return }
        self.key = key
        self.buckets = buckets
        self.undatedCount = undatedCount
        run += 1
        revision += 1
        switch state {
        case .picks(let picks):
            let kept = picks.compactMap { pick in current(pick.bucket).map(pick.updated(to:)) }
            if kept.isEmpty {
                state = .idle
                isStale = false
            } else {
                state = .picks(kept)
                markStale()
            }
        case .fallback:
            markStale()
        case .idle, .loading:
            state = .idle
        }
    }

    private func markStale() {
        isStale = true
        if staleSince == nil { staleSince = clock.now() }
    }

    /// Asks the model for picks unless they are already here and current. Cancelling the calling task (the
    /// Overview went away, or the groups changed again) leaves what is shown as it is.
    public func generateIfNeeded() async {
        guard availability.isAvailable, !buckets.isEmpty else { return }
        // A model that gave no answer is left alone until `retryAfter` has passed, whatever has changed since.
        if let failedAt, clock.now() - failedAt < retryAfter {
            // Nothing left to show must not read as "still working".
            if state == .idle { state = .fallback }
            return
        }
        let hasShown: Bool
        switch state {
        case .idle, .loading:
            hasShown = false
        case .picks:
            guard isStale else { return }
            hasShown = true
        case .fallback:
            hasShown = true
        }
        if hasShown {
            // Wait for the groups to be quiet; a refresh never starves while they keep changing.
            if isStale {
                let waited = staleSince.map { clock.now() - $0 } ?? .zero
                if waited < maximumStaleness {
                    try? await clock.sleep(min(debounce, maximumStaleness - waited))
                }
            }
            guard !Task.isCancelled else { return }
        } else {
            state = .loading
        }
        run += 1
        let mine = run
        requests += 1
        let outcome = await picker.picks(from: buckets)
        // Superseded by newer groups or a newer request: that one owns the state.
        guard mine == run else { return }
        switch outcome {
        case .picks(let picks):
            state = .picks(picks)
            failedAt = nil
        case .fallback:
            if case .picks = state {} else { state = .fallback }
            failedAt = clock.now()
        case .cancelled:
            if state == .loading { state = .idle }
            return
        }
        isStale = false
        staleSince = nil
    }
}
