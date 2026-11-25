import DownscaleVideo
import Foundation
import Observation

/// The Overview's groups of videos and, when the model is available, its picks among them.
///
/// The groups are plain Swift and always there. Picks are asked for once per `key` (the caller's summary of
/// everything the groups depend on: the libraries, the preset and the finished conversions) and kept until the
/// key changes, so reopening the Overview doesn't ask again. A failed answer is kept too, so a refusing model
/// isn't asked over and over. A cancelled request changes nothing.
@MainActor
@Observable
public final class SmartPicksStore {
    public enum State: Sendable, Equatable {
        /// Not asked yet, or the request was cancelled.
        case idle
        case loading
        case picks([SmartPick])
        /// The model gave no usable answer: the view lists the biggest groups.
        case fallback
    }

    public let availability: AssistantAvailability
    public private(set) var state = State.idle
    /// Every group that could free something, the biggest first.
    public private(set) var buckets: [SavingsBucket] = []
    /// Changes whenever the groups are replaced; a view uses it to know when to ask again.
    public private(set) var revision = 0

    @ObservationIgnored private let picker: SmartPicker
    @ObservationIgnored private var key: AnyHashable?
    @ObservationIgnored private var run = 0

    /// Test seam: how many times the model was asked.
    @ObservationIgnored public private(set) var requests = 0

    public init(availability: AssistantAvailability, picker: SmartPicker) {
        self.availability = availability
        self.picker = picker
    }

    /// Whether any AI wording may be shown: the model is available and has not failed for these groups.
    public var isShowingPicks: Bool {
        guard availability.isAvailable else { return false }
        switch state {
        case .idle, .loading, .picks: return true
        case .fallback: return false
        }
    }

    /// Replaces the groups. When `key` is the same as last time nothing changes, so picks stay.
    public func update(buckets: [SavingsBucket], key: some Hashable) {
        let key = AnyHashable(key)
        guard key != self.key else { return }
        self.key = key
        self.buckets = buckets
        run += 1
        state = .idle
        revision += 1
    }

    /// Asks the model for picks unless they are already here. Cancelling the calling task leaves the state as it
    /// was (not asked), so the next call asks again.
    public func generateIfNeeded() async {
        guard availability.isAvailable, !buckets.isEmpty else { return }
        switch state {
        case .picks, .fallback: return
        case .idle, .loading: break
        }
        run += 1
        let mine = run
        state = .loading
        requests += 1
        let outcome = await picker.picks(from: buckets)
        // Superseded by newer groups or a newer request: that one owns the state.
        guard mine == run else { return }
        switch outcome {
        case .picks(let picks): state = .picks(picks)
        case .fallback: state = .fallback
        case .cancelled: state = .idle
        }
    }
}
