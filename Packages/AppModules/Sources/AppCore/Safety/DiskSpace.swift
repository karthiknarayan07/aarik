import Foundation

/// One volume and how much room it has for work the user started (`volumeAvailableCapacityForImportantUsage`,
/// which counts space the system can purge).
public struct VolumeSpace: Sendable, Equatable {
    /// Identifies the volume, so needs on the same volume add up.
    public let id: String
    /// The name the user knows it by (Finder's name for the volume).
    public let name: String
    public let availableBytes: Int64

    public init(id: String, name: String, availableBytes: Int64) {
        self.id = id
        self.name = name
        self.availableBytes = availableBytes
    }
}

/// Answers how much room the volume holding a URL has. A seam: tests give a fake with chosen numbers.
public protocol DiskSpaceProviding: Sendable {
    /// The volume that holds `url`, or that would hold it when it doesn't exist yet (the nearest existing parent
    /// decides). nil when the volume can't be read; callers then skip the check rather than block the job.
    func volume(containing url: URL) -> VolumeSpace?
}

/// The real thing: asks the file system.
public struct SystemDiskSpace: DiskSpaceProviding {
    public init() {}

    public func volume(containing url: URL) -> VolumeSpace? {
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent == existing { return nil }
            existing = parent
        }
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey, .volumeNameKey, .volumeURLKey,
        ]
        guard let values = try? existing.resourceValues(forKeys: keys),
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        let name = values.volumeLocalizedName ?? values.volumeName ?? "this volume"
        return VolumeSpace(id: values.volume?.path ?? name, name: name, availableBytes: available)
    }
}

/// Room needed for something that will be written at `url`.
public struct SpaceNeed: Sendable, Equatable {
    public let url: URL
    public let bytes: Int64

    public init(url: URL, bytes: Int64) {
        self.url = url
        self.bytes = bytes
    }
}

/// A volume that can't hold what a job needs. Nothing has been written when this is thrown.
public struct NotEnoughSpaceError: Error, LocalizedError, Equatable {
    public let volumeName: String
    public let neededBytes: Int64
    public let availableBytes: Int64

    public init(volumeName: String, neededBytes: Int64, availableBytes: Int64) {
        self.volumeName = volumeName
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
    }

    public var errorDescription: String? {
        "Not enough free space on \(volumeName) (needs about \(Self.format(neededBytes)), "
            + "has \(Self.format(availableBytes)))"
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension NotEnoughSpaceError: OutcomeCoded {
    public var outcomeCode: OutcomeCode { .notEnoughSpace }
}

/// The free-space rule: on every volume involved, the free space must cover what will be written there plus a
/// margin, so a job never fills a disk.
public struct DiskSpaceCheck: Sendable {
    /// Left free on top of what a job writes: 1 GB.
    public static let margin: Int64 = 1_000_000_000

    private let provider: any DiskSpaceProviding

    public init(provider: any DiskSpaceProviding = SystemDiskSpace()) {
        self.provider = provider
    }

    /// Throws `NotEnoughSpaceError` for the first volume (in the order given) whose free space is below the sum of
    /// the needs on it plus `margin`. A volume that can't be read is not checked.
    public func verify(_ needs: [SpaceNeed]) throws {
        var order: [String] = []
        var totals: [String: (volume: VolumeSpace, bytes: Int64)] = [:]
        for need in needs {
            guard let volume = provider.volume(containing: need.url) else { continue }
            if totals[volume.id] == nil { order.append(volume.id) }
            let sum = Self.add(totals[volume.id]?.bytes ?? 0, max(need.bytes, 0))
            totals[volume.id] = (volume, sum)
        }
        for id in order {
            guard let entry = totals[id] else { continue }
            let required = Self.add(entry.bytes, Self.margin)
            if entry.volume.availableBytes < required {
                throw NotEnoughSpaceError(
                    volumeName: entry.volume.name, neededBytes: required, availableBytes: entry.volume.availableBytes)
            }
        }
    }

    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : sum
    }
}
