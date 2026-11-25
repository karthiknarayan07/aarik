import Foundation

/// Persists the job list as `jobs.json` inside a directory, written atomically.
public struct JobStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("jobs.json") }

    /// What `loadReportingProblems` found.
    public struct Loaded: Sendable {
        public var jobs: [Job]
        /// Where an unreadable `jobs.json` (damaged, or written by a newer version) was moved; nil if none was.
        public var setAside: URL?
    }

    /// Returns the saved jobs, or an empty list if nothing readable is stored (an unreadable file is set aside).
    public func load() -> [Job] {
        loadReportingProblems().jobs
    }

    /// The saved jobs. A `jobs.json` that can't be decoded is moved to `jobs.json.corrupt-<timestamp>` rather than
    /// being overwritten by the next save, and the list starts empty.
    public func loadReportingProblems() -> Loaded {
        guard let data = try? Data(contentsOf: fileURL) else { return Loaded(jobs: [], setAside: nil) }
        if let jobs = try? JSONDecoder().decode([Job].self, from: data) { return Loaded(jobs: jobs, setAside: nil) }
        let stamp = Date().formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
        for suffix in [stamp, "\(stamp)-\(UUID().uuidString)"] {
            let aside = directory.appendingPathComponent("jobs.json.corrupt-\(suffix)")
            if (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil {
                return Loaded(jobs: [], setAside: aside)
            }
        }
        return Loaded(jobs: [], setAside: nil)
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }
}
