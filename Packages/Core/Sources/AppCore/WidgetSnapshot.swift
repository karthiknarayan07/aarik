import Foundation

/// Resolves the shared App Group identifier and container URL from a bundle's Info.plist (`AppGroupID`).
public enum AppGroup {
    public static let infoKey = "AppGroupID"

    /// Returns the configured App Group identifier from `bundle`, or nil when missing or unexpanded.
    public static func identifier(in bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: infoKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// Returns the App Group container URL for `bundle`, or nil when unavailable (for example in unsigned unit tests).
    public static func containerURL(in bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        guard let id = identifier(in: bundle) else { return nil }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Darwin notification name used to signal shared pause-flag changes across processes.
    public static func pauseNotificationName(forGroupID groupID: String) -> String {
        "\(groupID).queuePauseFlagChanged"
    }

    /// Darwin notification name derived from `bundle`'s configured App Group identifier.
    public static func pauseNotificationName(in bundle: Bundle = .main) -> String? {
        identifier(in: bundle).map(pauseNotificationName(forGroupID:))
    }
}

/// Stable WidgetKit and ControlWidget kind identifiers shared between the iOS app and the Widgets extension.
public enum WidgetKinds {
    public static let summary = "QueueSummaryWidget"
    public static let pauseControl = "QueuePauseControl"
}

/// Queue summary written by the app to the App Group container and read by the Home Screen widget.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var savedBytes: Int64
    public var queueCount: Int
    public var completedCount: Int
    public var isPaused: Bool
    public var updatedAt: Date

    public static let empty = WidgetSnapshot()

    public init(
        savedBytes: Int64 = 0,
        queueCount: Int = 0,
        completedCount: Int = 0,
        isPaused: Bool = false,
        updatedAt: Date = .now
    ) {
        self.savedBytes = max(0, savedBytes)
        self.queueCount = max(0, queueCount)
        self.completedCount = max(0, completedCount)
        self.isPaused = isPaused
        self.updatedAt = updatedAt
    }

    public init(activity: ActivitySummary, isPaused: Bool = false, updatedAt: Date = .now) {
        self.init(
            savedBytes: activity.savedBytes,
            queueCount: activity.queue,
            completedCount: activity.completed,
            isPaused: isPaused,
            updatedAt: updatedAt
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decodeIfPresent(Int64.self, forKey: .savedBytes) ?? 0
        let queued = try container.decodeIfPresent(Int.self, forKey: .queueCount) ?? 0
        let completed = try container.decodeIfPresent(Int.self, forKey: .completedCount) ?? 0
        let paused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        let updated = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        self.init(
            savedBytes: saved,
            queueCount: queued,
            completedCount: completed,
            isPaused: paused,
            updatedAt: updated
        )
    }

    /// Compares the displayed fields, ignoring `updatedAt`, so unchanged states don't trigger timeline reloads.
    public func hasSameContent(as other: WidgetSnapshot) -> Bool {
        savedBytes == other.savedBytes
            && queueCount == other.queueCount
            && completedCount == other.completedCount
            && isPaused == other.isPaused
    }
}

/// Persists `WidgetSnapshot` atomically inside a shared container directory.
public struct WidgetSnapshotStore: Sendable {
    public static let defaultFileName = "widget-snapshot.json"

    public let directory: URL
    public let fileURL: URL

    public init(directory: URL, fileName: String = defaultFileName) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    /// Creates a store backed by the bundle's App Group container, or returns nil when no container is configured.
    public init?(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        fileName: String = defaultFileName
    ) {
        guard let container = AppGroup.containerURL(in: bundle, fileManager: fileManager) else { return nil }
        self.init(directory: container, fileName: fileName)
    }

    /// Reads the current snapshot, returning nil if missing or unreadable.
    public func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Reads the current snapshot or returns `.empty` when none is saved yet.
    public func loadOrEmpty() -> WidgetSnapshot {
        load() ?? .empty
    }

    /// Writes `snapshot` atomically, creating the container directory if needed.
    public func save(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Writes `snapshot` only when its displayed content differs from the saved snapshot; returns true if written.
    @discardableResult
    public func saveIfChanged(_ snapshot: WidgetSnapshot) throws -> Bool {
        if let existing = load(), existing.hasSameContent(as: snapshot) {
            return false
        }
        try save(snapshot)
        return true
    }
}
