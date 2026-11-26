import Foundation

/// What the menu bar popover says about the quick runs started from the menu bar: any number at once, so a second
/// drop never hides the first run's result. Pure state; the app feeds it events and shows `lines`.
public struct MenuBarRunBoard: Sendable, Equatable {
    /// How long a finished run's "Done" line stays when nobody opens the popover.
    public static let doneLifetime: TimeInterval = 10 * 60
    /// How long a brief message such as "Nothing to shrink" stays.
    public static let noticeLifetime: TimeInterval = 4

    /// One drop or choice of files, from the moment it is checked until its result has been seen.
    public struct Entry: Sendable, Equatable, Identifiable {
        public enum Phase: Sendable, Equatable {
            /// Files are being checked before anything is queued.
            case checking(files: Int)
            /// Jobs are queued or converting.
            case running(videos: Int)
            case finished(QuickRunTally, at: Date)
        }

        /// Names this entry before its run exists.
        public let id: UUID
        public var runID: UUID?
        public var phase: Phase
        /// The run's jobs, so an entry stuck on "running" can be cleared when they are gone.
        public var jobIDs: Set<UUID>
        /// Items of the drop that looked like movies by name but weren't (a folder named x.mov, an unreadable
        /// file): reported as skipped.
        public var rejected: Int
        /// Whether the popover was open once the run had finished, so the next opening can clear the line.
        public var seen: Bool

        public var isFinished: Bool {
            if case .finished = phase { true } else { false }
        }
    }

    /// A brief message that goes by itself.
    public struct Notice: Sendable, Equatable {
        public let text: String
        public let expires: Date
    }

    /// A run's result that arrived before the run was attached to its entry.
    private struct Early: Sendable, Equatable {
        let tally: QuickRunTally
        let at: Date
        let seen: Bool
    }

    public private(set) var entries: [Entry] = []
    public private(set) var notice: Notice?
    private var early: [UUID: Early] = [:]

    public init() {}

    // MARK: - Events

    /// A drop or choice of `files` items is being checked. Returns the entry's name for the later events.
    public mutating func begin(files: Int) -> UUID {
        let id = UUID()
        entries.append(Entry(id: id, runID: nil, phase: .checking(files: files), jobIDs: [], rejected: 0, seen: false))
        return id
    }

    /// The check is done: `movies` go on, `rejected` looked like movies but aren't. With no movie at all the entry
    /// goes and a brief "Nothing to shrink" shows instead, so a drop with nothing valid never replaces the status of
    /// a run that is going.
    public mutating func checked(_ id: UUID, movies: Int, rejected: Int, now: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if movies == 0 {
            entries.remove(at: index)
            let text = rejected > 0 ? "Nothing to shrink, \(rejected) skipped" : "Nothing to shrink"
            notice = Notice(text: text, expires: now.addingTimeInterval(Self.noticeLifetime))
        } else {
            entries[index].phase = .checking(files: movies)
            entries[index].rejected = rejected
        }
    }

    /// The run's files are sorted into queued and skipped. If the run's notice came first, it already ended.
    public mutating func queued(
        _ id: UUID, runID: UUID, jobIDs: [UUID], skipped: Int, now: Date, popoverVisible: Bool
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            early[runID] = nil
            return
        }
        entries[index].runID = runID
        entries[index].jobIDs = Set(jobIDs)
        if let result = early.removeValue(forKey: runID) {
            entries[index].phase = .finished(result.tally, at: result.at)
            entries[index].seen = result.seen
        } else if jobIDs.isEmpty {
            entries[index].phase = .finished(QuickRunTally(converted: 0, skipped: skipped, failed: 0), at: now)
            entries[index].seen = popoverVisible
        } else {
            entries[index].phase = .running(videos: jobIDs.count)
        }
    }

    /// The run ended with `tally`. The notice can arrive before the entry knows its run (a run with nothing to queue
    /// ends inside `QuickRun.run`), so the result waits for it.
    public mutating func finished(runID: UUID, tally: QuickRunTally, now: Date, popoverVisible: Bool) {
        if let index = entries.firstIndex(where: { $0.runID == runID }) {
            entries[index].phase = .finished(tally, at: now)
            entries[index].seen = popoverVisible
        } else {
            early[runID] = Early(tally: tally, at: now, seen: popoverVisible)
        }
    }

    /// Clears runs whose jobs were all removed by hand: they never get a notice, and would say "Shrinking" forever.
    public mutating func dropStale(presentJobs: Set<UUID>) {
        entries.removeAll { entry in
            guard case .running = entry.phase, !entry.jobIDs.isEmpty else { return false }
            return entry.jobIDs.isDisjoint(with: presentJobs)
        }
    }

    /// Removes what has outlived its time.
    public mutating func prune(now: Date) {
        entries.removeAll { entry in
            guard case .finished(_, let at) = entry.phase else { return false }
            return now.timeIntervalSince(at) >= Self.doneLifetime
        }
        early = early.filter { now.timeIntervalSince($0.value.at) < Self.doneLifetime }
        if let notice, notice.expires <= now { self.notice = nil }
    }

    /// The popover is opening: a result the person has already seen goes, and what is left counts as seen once it
    /// is on screen.
    public mutating func popoverOpened(now: Date) {
        prune(now: now)
        entries.removeAll { $0.isFinished && $0.seen }
        for index in entries.indices where entries[index].isFinished { entries[index].seen = true }
    }

    // MARK: - What to show

    /// Whether a run is still being checked or converted.
    public var isActive: Bool { entries.contains { !$0.isFinished } }

    public var isEmpty: Bool { entries.isEmpty && notice == nil }

    /// The status lines: what is going on, then one combined tally of everything that finished.
    public var lines: [String] {
        var checking = 0
        var running = 0
        var tally = QuickRunTally(converted: 0, skipped: 0, failed: 0)
        var anyFinished = false
        for entry in entries {
            switch entry.phase {
            case .checking(let files): checking += files
            case .running(let videos): running += videos
            case .finished(let result, _):
                anyFinished = true
                tally = QuickRunTally(
                    converted: tally.converted + result.converted,
                    skipped: tally.skipped + result.skipped + entry.rejected, failed: tally.failed + result.failed)
            }
        }
        var lines: [String] = []
        if checking > 0 { lines.append("Checking \(Self.videos(checking))…") }
        if running > 0 { lines.append("Shrinking \(Self.videos(running))…") }
        if anyFinished { lines.append("Done: " + Self.summary(tally)) }
        return lines
    }

    /// Finished runs with skipped videos to look at, oldest first.
    public var reviewRunIDs: [UUID] {
        entries.compactMap { entry in
            guard case .finished(let tally, _) = entry.phase, tally.skipped > 0 else { return nil }
            return entry.runID
        }
    }

    private static func videos(_ count: Int) -> String { "\(count) \(count == 1 ? "video" : "videos")" }

    private static func summary(_ tally: QuickRunTally) -> String {
        var parts: [String] = []
        if tally.converted > 0 { parts.append("\(tally.converted) shrunk") }
        if tally.skipped > 0 { parts.append("\(tally.skipped) skipped") }
        if tally.failed > 0 { parts.append("\(tally.failed) failed") }
        return parts.isEmpty ? "nothing to shrink" : parts.joined(separator: ", ")
    }
}

/// Where the Settings help rows send the person in System Settings.
public enum SystemSettingsPane {
    /// The Keyboard pane. Keyboard Shortcuts ▸ Services is a sheet inside it, and no link reaches a sheet, so this is
    /// as close as a link gets (the pane's "Keyboard Shortcuts…" button is one click away).
    public static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    /// The Notifications pane, with the app's own entry when the system knows the link's `id`.
    public static func notifications(bundleIdentifier: String?) -> URL? {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
            let id = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return URL(string: base) }
        return URL(string: base + "?id=" + id)
    }
}
