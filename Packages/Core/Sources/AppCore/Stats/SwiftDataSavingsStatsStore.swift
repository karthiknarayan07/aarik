import Foundation
import SwiftData

/// The stats snapshot row: one per store, keyed so a save replaces it.
@Model final class StatsSnapshotRecord {
    @Attribute(.unique) var key: String
    var version: Int
    var updatedAt: Date
    var savedBytes: Int64
    var conversions: Int
    /// The libraries and groups, encoded; the history is in its own rows.
    var payload: Data

    init(key: String, version: Int, updatedAt: Date, savedBytes: Int64, conversions: Int, payload: Data) {
        self.key = key
        self.version = version
        self.updatedAt = updatedAt
        self.savedBytes = savedBytes
        self.conversions = conversions
        self.payload = payload
    }
}

/// The savings history: one row per day, a time series for the charts.
@Model final class SavingsHistoryRecord {
    @Attribute(.unique) var day: Date
    var videos: Int
    var savedBytes: Int64

    init(day: Date, videos: Int, savedBytes: Int64) {
        self.day = day
        self.videos = videos
        self.savedBytes = savedBytes
    }
}

/// Keeps the snapshot in a SwiftData store in Application Support. The store opens on first use, off the main actor. A
/// store that can't be opened or read is deleted and made again, so it is only a cache that starts empty. Other files
/// (jobs.json, library.json) are never touched.
public actor SwiftDataSavingsStatsStore: SavingsStatsStore {
    private struct Payload: Codable {
        var libraries: [SavingsSnapshot.Library]
        var groups: [SavingsSnapshot.Group]
    }

    private static let key = "current"
    public static let fileName = "SavingsStats.store"

    private let url: URL?
    private var container: ModelContainer?
    private var openFailed = false

    /// `directory` holds the store file; nil keeps it in memory (for tests).
    public init(directory: URL?) {
        self.url = directory?.appending(path: Self.fileName)
    }

    private func openContainer() -> ModelContainer? {
        if let container { return container }
        if openFailed { return nil }
        let schema = Schema([StatsSnapshotRecord.self, SavingsHistoryRecord.self])
        let url = url
        func make() throws -> ModelContainer {
            let configuration: ModelConfiguration
            if let url {
                configuration = ModelConfiguration(schema: schema, url: url)
            } else {
                configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            }
            return try ModelContainer(for: schema, configurations: configuration)
        }
        do {
            container = try make()
        } catch {
            // A cache can always be rebuilt: start again from nothing.
            removeStoreFiles()
            do {
                container = try make()
            } catch {
                openFailed = true
            }
        }
        return container
    }

    private func removeStoreFiles() {
        guard let url else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix))
        }
    }

    public func load() -> SavingsSnapshot? {
        guard let container = openContainer() else { return nil }
        let context = ModelContext(container)
        do {
            let key = Self.key
            guard
                let record = try context.fetch(
                    FetchDescriptor<StatsSnapshotRecord>(predicate: #Predicate { $0.key == key })
                ).first
            else { return nil }
            guard record.version == SavingsSnapshot.currentVersion,
                let payload = try? JSONDecoder().decode(Payload.self, from: record.payload)
            else {
                discard(context)
                return nil
            }
            let history = try context.fetch(
                FetchDescriptor<SavingsHistoryRecord>(sortBy: [SortDescriptor(\.day)]))
            return SavingsSnapshot(
                updatedAt: record.updatedAt, libraries: payload.libraries, groups: payload.groups,
                days: history.map { SavingsSnapshot.Day(day: $0.day, videos: $0.videos, savedBytes: $0.savedBytes) },
                savedBytes: record.savedBytes, conversions: record.conversions)
        } catch {
            discard(context)
            return nil
        }
    }

    public func save(_ snapshot: SavingsSnapshot) {
        guard let container = openContainer(),
            let payload = try? JSONEncoder().encode(
                Payload(libraries: snapshot.libraries, groups: snapshot.groups))
        else { return }
        let context = ModelContext(container)
        do {
            try context.delete(model: StatsSnapshotRecord.self)
            try context.delete(model: SavingsHistoryRecord.self)
            context.insert(
                StatsSnapshotRecord(
                    key: Self.key, version: snapshot.version, updatedAt: snapshot.updatedAt,
                    savedBytes: snapshot.savedBytes, conversions: snapshot.conversions, payload: payload))
            for day in snapshot.days {
                context.insert(SavingsHistoryRecord(day: day.day, videos: day.videos, savedBytes: day.savedBytes))
            }
            try context.save()
        } catch {
            // Only a cache: the next refresh writes it again.
        }
    }

    public func clear() {
        guard let container = openContainer() else { return }
        discard(ModelContext(container))
    }

    private func discard(_ context: ModelContext) {
        try? context.delete(model: StatsSnapshotRecord.self)
        try? context.delete(model: SavingsHistoryRecord.self)
        try? context.save()
    }
}
