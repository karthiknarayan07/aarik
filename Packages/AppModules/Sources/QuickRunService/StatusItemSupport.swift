import AppKit
import Foundation
import UniformTypeIdentifiers

extension MovieDropFilter {
    /// A guess from the file name alone, with no disk access: whether this looks like a movie. Used while a drag is
    /// over the status item, where touching the disk for every file would stall the main thread.
    public static func looksLikeMovie(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath,
            let type = UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .movie)
    }

    /// Whether any of `urls` looks like a movie (see `looksLikeMovie`).
    public static func mightContainMovie(_ urls: [URL]) -> Bool {
        urls.contains(where: looksLikeMovie)
    }

    /// The file URLs on a pasteboard, read without checking the files.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// The answer for one drag session, worked out once when the drag enters and reused for every later update.
public struct DragVerdictCache: Sendable, Equatable {
    private var sequence: Int?
    private var verdict = false

    public init() {}

    /// The verdict for the drag session `sequence`, computing it only the first time that session is asked about.
    public mutating func verdict(forSession sequence: Int, compute: () -> Bool) -> Bool {
        if self.sequence != sequence {
            self.sequence = sequence
            verdict = compute()
        }
        return verdict
    }

    /// Forgets the session, so the next drag is judged afresh.
    public mutating func reset() {
        sequence = nil
        verdict = false
    }
}

/// Whether opening the popover should activate the app. A pointer click leaves the app and the windows in front
/// alone, like Apple's menu bar extras; opening it from the keyboard or with VoiceOver activates, because an
/// inactive app's popover can't take keystrokes.
public enum PopoverActivation {
    public static func shouldActivate(openedBy eventType: NSEvent.EventType?) -> Bool {
        !StatusItemHitTest.passesThrough(eventType)
    }
}

/// What the popover says about the current or most recent quick run started from the menu bar.
public struct QuickRunStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Files are being checked before anything is queued.
        case checking(files: Int)
        /// Jobs are queued or converting.
        case running(videos: Int)
        case finished(QuickRunTally)
    }

    public var runID: UUID?
    public var phase: Phase
    /// The run's jobs, so a status stuck on "running" can be cleared when they are gone.
    public var jobIDs: Set<UUID>

    public init(runID: UUID? = nil, phase: Phase, jobIDs: Set<UUID> = []) {
        self.runID = runID
        self.phase = phase
        self.jobIDs = jobIDs
    }

    public var text: String {
        switch phase {
        case .checking(let files): "Checking \(files) \(files == 1 ? "video" : "videos")…"
        case .running(let videos): "Shrinking \(videos) \(videos == 1 ? "video" : "videos")…"
        case .finished(let tally): "Done: " + Self.summary(tally)
        }
    }

    private static func summary(_ tally: QuickRunTally) -> String {
        var parts: [String] = []
        if tally.converted > 0 { parts.append("\(tally.converted) shrunk") }
        if tally.skipped > 0 { parts.append("\(tally.skipped) skipped") }
        if tally.failed > 0 { parts.append("\(tally.failed) failed") }
        return parts.isEmpty ? "nothing to shrink" : parts.joined(separator: ", ")
    }

    /// Skipped files can be reviewed once the run is done.
    public var skippedCount: Int {
        if case .finished(let tally) = phase { tally.skipped } else { 0 }
    }

    /// Whether it still says the run is going.
    public var isActive: Bool {
        if case .finished = phase { false } else { true }
    }
}
