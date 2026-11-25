import Foundation

/// Persists the job list as `jobs.json` inside a directory, written atomically.
public struct JobStore: Sendable {
    public let directory: URL
    /// Moves an unreadable file aside; a seam so tests can make that fail.
    var moveItem: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    public init(directory: URL) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("jobs.json") }

    /// What `loadReportingProblems` found.
    public struct Loaded: Sendable {
        public var jobs: [Job]
        /// Where an unreadable `jobs.json` (damaged, or written by a newer version) was moved; nil if none was.
        public var setAside: URL?
        /// `jobs.json` exists but couldn't be read, or couldn't be moved aside: saving would overwrite jobs that
        /// may still be readable later, so nothing must be saved over it.
        public var mustNotSave = false
    }

    /// Returns the saved jobs, or an empty list if nothing readable is stored (an unreadable file is set aside).
    public func load() -> [Job] {
        loadReportingProblems().jobs
    }

    /// The saved jobs. A `jobs.json` that can't be decoded is moved to `jobs.json.corrupt-<timestamp>` rather than
    /// being overwritten by the next save, and the list starts empty. One that exists but can't be read (or can't
    /// be moved aside) is left where it is and marked `mustNotSave`.
    public func loadReportingProblems() -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let missing = !FileManager.default.fileExists(atPath: fileURL.path)
            return Loaded(jobs: [], setAside: nil, mustNotSave: !missing)
        }
        if let jobs = try? JSONDecoder().decode([Job].self, from: data) { return Loaded(jobs: jobs, setAside: nil) }
        let stamp = Date().formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
        for suffix in [stamp, "\(stamp)-\(UUID().uuidString)"] {
            let aside = directory.appendingPathComponent("jobs.json.corrupt-\(suffix)")
            if (try? moveItem(fileURL, aside)) != nil {
                return Loaded(jobs: [], setAside: aside)
            }
        }
        return Loaded(jobs: [], setAside: nil, mustNotSave: true)
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }
}
