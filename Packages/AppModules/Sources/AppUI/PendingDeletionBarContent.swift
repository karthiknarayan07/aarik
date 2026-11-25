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

    /// Originals the bar is about (those that moved, for `.moved`).
    public let count: Int
    public let status: Status

    public init(count: Int, status: Status) {
        self.count = count
        self.status = status
    }

    /// Photos frees the space when Recently Deleted is emptied, which it also does by itself after 30 days.
    public static let spaceNote = "iCloud space is freed when Recently Deleted is emptied, or after 30 days."
    public static let declinedTitle = "Originals kept. You can move them to Recently Deleted later."
    public static let actionTitle = "Move Originals to Recently Deleted…"

    public var title: String {
        switch status {
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
        switch status {
        case .ready: "The smaller copies are already in your library. \(Self.spaceNote)"
        case .declined: Self.spaceNote
        case .working: "Photos asks you to confirm."
        case .moved(let savedBytes):
            savedBytes > 0
                ? "You've saved \(ByteFormat.string(savedBytes)) in total. \(Self.spaceNote)" : Self.spaceNote
        case .failed(let reason): reason
        }
    }

    /// The button's title; nil when there is nothing to press (while waiting).
    public var buttonTitle: String? {
        switch status {
        case .ready, .declined, .failed: Self.actionTitle
        case .working: nil
        case .moved: "Done"
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

    /// One sentence for VoiceOver.
    public var accessibilityLabel: String { "\(title). \(detail)" }
}
