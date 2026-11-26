import AarikCore
import Foundation

/// The four Activity lists.
public enum JobListKind: Sendable, CaseIterable {
    case queue, completed, keptAsIs, failed
}

/// What the actions of a row need to know about it.
public struct JobRowFacts: Equatable, Sendable {
    public var isRunning: Bool
    /// The row has a file to reveal in Finder: its source, or for a finished conversion its output. A Photos video
    /// has none.
    public var hasFile: Bool

    public init(isRunning: Bool = false, hasFile: Bool) {
        self.isRunning = isRunning
        self.hasFile = hasFile
    }
}

public enum JobListAction: Hashable, Sendable {
    case showInFinder
    case retry
    /// Takes a waiting video out of the queue, or stops the one converting.
    case removeFromQueue
    /// Drops a finished row from its list. Files are never touched.
    case removeFromList
}

public struct JobListCommand: Equatable, Sendable {
    public let action: JobListAction
    public let title: String
}

/// What a selection in an Activity list can do: the context menu, double-click and Return, and Delete. Pure, so
/// each list's behaviour is tested here, and the views only perform what comes back.
public enum JobListActions {
    /// The context menu for the selected rows, in order. Empty for no selection (a click on empty space).
    public static func contextMenu(kind: JobListKind, rows: [JobRowFacts]) -> [JobListCommand] {
        guard !rows.isEmpty else { return [] }
        var commands: [JobListCommand] = []
        if kind == .failed {
            commands.append(JobListCommand(action: .retry, title: "Retry"))
        }
        if rows.allSatisfy(\.hasFile) {
            commands.append(JobListCommand(action: .showInFinder, title: "Show in Finder"))
        }
        if let removal = deleteAction(kind: kind, rows: rows) {
            commands.append(JobListCommand(action: removal, title: title(of: removal, rows: rows)))
        }
        return commands
    }

    /// Double-click or Return: reveal the file; a failed video without one is retried.
    public static func primary(kind: JobListKind, rows: [JobRowFacts]) -> JobListAction? {
        guard !rows.isEmpty else { return nil }
        if rows.allSatisfy(\.hasFile) { return .showInFinder }
        return kind == .failed ? .retry : nil
    }

    /// Delete: out of the queue for waiting videos; for finished ones, only the row goes.
    public static func deleteAction(kind: JobListKind, rows: [JobRowFacts]) -> JobListAction? {
        guard !rows.isEmpty else { return nil }
        return kind == .queue ? .removeFromQueue : .removeFromList
    }

    static func title(of action: JobListAction, rows: [JobRowFacts]) -> String {
        switch action {
        case .showInFinder: "Show in Finder"
        case .retry: "Retry"
        case .removeFromQueue: rows.count == 1 && rows[0].isRunning ? "Cancel Conversion" : "Remove from Queue"
        case .removeFromList: "Remove from List"
        }
    }

    /// The window subtitle of a list: its count, with what the queue is waiting for, or what the list saved.
    public static func subtitle(kind: JobListKind, count: Int, savedBytes: Int64, pauseText: String?) -> String {
        guard count > 0 else { return kind == .queue ? pauseText ?? "" : "" }
        var parts = [ActivityText.videos(count)]
        switch kind {
        case .queue: if let pauseText { parts.append(pauseText) }
        case .completed: parts.append("Saved \(ByteFormat.string(savedBytes))")
        case .keptAsIs, .failed: break
        }
        return parts.joined(separator: " · ")
    }
}
