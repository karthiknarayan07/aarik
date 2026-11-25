import Foundation

/// Persists the job list as `jobs.json` inside a directory, written atomically.
public struct JobStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("jobs.json") }

    /// Returns the saved jobs, or an empty list if nothing readable is stored.
    public func load() -> [Job] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Job].self, from: data)) ?? []
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }
}
