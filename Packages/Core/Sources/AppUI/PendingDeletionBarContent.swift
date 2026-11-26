import Foundation

/// What the pending-deletion bar says. The words live here so they can be tested; the bar only lays them out.
///
/// The bar never claims more than the app knows: Photos can't list Recently Deleted, so "moved" rests on Photos
/// accepting the delete and the original no longer being found.
public struct PendingDeletionBarContent: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Originals wait for the user to move them.
        case ready
        /// The user declined the system confirmation; the originals are kept and still wait.
        case declined
        /// Waiting for Photos and the user's confirmation.
        case working
        /// The originals were moved; `savedBytes` is what all finished conversions have saved.
        case moved(savedBytes: Int64)
        /// Photos refused or the delete failed; the text says why.
        case failed(String)
    }

    /// Originals the bar is about (those that moved, for `.moved`); the ones that can go in the next batch.
    public let count: Int
    public let status: Status
    /// Originals kept out of the batch, with a reason each: how many, the distinct reasons, whether looking again
    /// can help (a limited-access block), and whether System Settings is where to fix it.
    public let heldCount: Int
    public let heldMessages: [String]
    public let heldCanRetry: Bool
    public let heldNeedsSettings: Bool

    public init(
        count: Int, status: Status, heldCount: Int = 0, heldMessages: [String] = [], heldCanRetry: Bool = false,
        heldNeedsSettings: Bool = false
    ) {
        self.count = count
        self.status = status
        self.heldCount = heldCount
        self.heldMessages = heldMessages
        self.heldCanRetry = heldCanRetry
        self.heldNeedsSettings = heldNeedsSettings
    }

    /// Takes the originals off the list without deleting anything.
    public static let removeTitle = "Remove from List"
    public static let settingsTitle = "Open System Settings…"

    /// Photos frees the space when Recently Deleted is emptied, which it also does by itself after 30 days.
    public static let spaceNote = "iCloud space is freed when Recently Deleted is emptied, or after 30 days."
    public static let declinedTitle = "Originals kept. You can move them to Recently Deleted later."
    public static let actionTitle = "Move Originals to Recently Deleted…"

    public var title: String {
        switch status {
        case .ready where count == 0:
            heldCount == 1 ? "1 original was kept in Photos" : "\(heldCount) originals were kept in Photos"
        case .ready:
            count == 1
                ? "1 original is ready to move to Recently Deleted"
                : "\(count) originals are ready to move to Recently Deleted"
        case .declined: Self.declinedTitle
        case .working: "Moving originals to Recently Deleted…"
        case .moved:
            count == 1 ? "1 original moved to Recently Deleted" : "\(count) originals moved to Recently Deleted"
        case .failed: "Couldn't move originals to Recently Deleted"
        }
    }

    public var detail: String {
        let held = heldMessages.joined(separator: "\n")
        let base: String =
            switch status {
            case .ready: count == 0 ? "" : "The smaller copies are already in your library. \(Self.spaceNote)"
            case .declined: Self.spaceNote
            case .working: "Photos asks you to confirm."
            case .moved(let savedBytes):
                savedBytes > 0
                    ? "You've saved \(ByteFormat.string(savedBytes)) in total. \(Self.spaceNote)" : Self.spaceNote
            case .failed(let reason): reason
            }
        switch status {
        case .ready, .declined, .failed: return [base, held].filter { !$0.isEmpty }.joined(separator: "\n")
        case .working, .moved: return base
        }
    }

    /// Whether the bar offers "Remove from List" (kept originals can be dismissed; nothing is deleted).
    public var offersRemove: Bool {
        guard heldCount > 0 else { return false }
        switch status {
        case .ready, .declined, .failed: return true
        case .working, .moved: return false
        }
    }

    public var offersSettings: Bool { heldNeedsSettings && offersRemove }

    /// The button's title; nil when there is nothing to press (while waiting).
    public var buttonTitle: String? {
        switch status {
        case .ready, .declined, .failed: count > 0 || heldCanRetry ? Self.actionTitle : nil
        case .working: nil
        case .moved: "Done"
        }
    }

    /// The button's title with the count included, for the iOS bar: `"Move 1 Original to Recently Deleted…"`,
    /// `"Move N Originals to Recently Deleted…"`, or `actionTitle` when retrying held originals.
    public var countedActionTitle: String? {
        switch status {
        case .ready, .declined, .failed:
            guard count > 0 || heldCanRetry else { return nil }
            if count == 1 { return "Move 1 Original to Recently Deleted…" }
            if count > 1 { return "Move \(count) Originals to Recently Deleted…" }
            return Self.actionTitle
        case .working:
            return nil
        case .moved:
            return "Done"
        }
    }

    /// Moving originals is the destructive choice (the bar styles it so); "Done" is not.
    public var isDestructiveAction: Bool {
        switch status {
        case .ready, .declined, .failed: true
        case .working, .moved: false
        }
    }

    public var isWorking: Bool { status == .working }
}
