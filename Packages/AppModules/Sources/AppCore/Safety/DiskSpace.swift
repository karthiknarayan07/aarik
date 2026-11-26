import Foundation
import Synchronization

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

/// Space promised to jobs that are running but haven't written it yet, per volume, so several jobs at once can't
/// each be told "there is room" for the same bytes. A job's reservation replaces its earlier one (a second, more exact
/// estimate) and is released when the job ends, whatever way. The margin is not stored: it is kept once per volume.
public final class SpaceLedger: Sendable {
    /// The reservations of this process; every runner uses it unless a test gives its own.
    public static let shared = SpaceLedger()

    private let reserved = Mutex<[UUID: [String: Int64]]>([:])

    public init() {}

    /// Runs `check` with the bytes the other owners have reserved on each volume in `totals`; when it doesn't throw,
    /// `totals` become `owner`'s reservation. One step under one lock, so two jobs can't both pass the same room.
    func reserve(
        _ totals: [String: Int64], order: [String], for owner: UUID,
        check: (_ volume: String, _ others: Int64) throws -> Void
    ) throws {
        try reserved.withLock { all in
            for volume in order {
                var others: Int64 = 0
                for (key, entry) in all where key != owner {
                    let (sum, overflow) = others.addingReportingOverflow(entry[volume] ?? 0)
                    others = overflow ? Int64.max : sum
                }
                try check(volume, others)
            }
            all[owner] = totals
        }
    }

    /// Gives back everything `owner` reserved.
    public func release(owner: UUID) {
        reserved.withLock { $0[owner] = nil }
    }

    /// Total reserved on a volume, for tests.
    public func total(on volume: String) -> Int64 {
        reserved.withLock { $0.values.reduce(0) { $0 + ($1[volume] ?? 0) } }
    }
}

/// The free-space rule: on every volume involved, the free space must cover what will be written there plus a
/// margin, so a job never fills a disk.
public struct DiskSpaceCheck: Sendable {
    /// Left free on top of what a job writes: 1 GB.
    public static let margin: Int64 = 1_000_000_000

    private let provider: any DiskSpaceProviding
    private let ledger: SpaceLedger

    public init(provider: any DiskSpaceProviding = SystemDiskSpace(), ledger: SpaceLedger = .shared) {
        self.provider = provider
        self.ledger = ledger
    }

    /// Gives back what `owner` (a job) reserved with `verify(_:reservingFor:)`.
    public func release(owner: UUID) { ledger.release(owner: owner) }

    /// Throws `NotEnoughSpaceError` for the first volume (in the order given) whose free space is below the sum of
    /// the needs on it plus `margin`. A volume that can't be read is not checked.
    ///
    /// With `owner` (a running job), space other jobs have reserved and not yet written counts as taken, and the
    /// needs are then reserved for `owner` (replacing its earlier reservation) until `release(owner:)`. A failed
    /// check reserves nothing. The margin is kept once per volume, not once per job.
    public func verify(_ needs: [SpaceNeed], reservingFor owner: UUID? = nil) throws {
        var order: [String] = []
        var totals: [String: (volume: VolumeSpace, bytes: Int64)] = [:]
        for need in needs {
            guard let volume = provider.volume(containing: need.url) else { continue }
            if totals[volume.id] == nil { order.append(volume.id) }
            let sum = Self.add(totals[volume.id]?.bytes ?? 0, max(need.bytes, 0))
            totals[volume.id] = (volume, sum)
        }
        func check(_ id: String, others: Int64) throws {
            guard let entry = totals[id] else { return }
            let required = Self.add(entry.bytes, Self.margin)
            let available = entry.volume.availableBytes - min(others, max(entry.volume.availableBytes, 0))
            if available < required {
                throw NotEnoughSpaceError(
                    volumeName: entry.volume.name, neededBytes: required, availableBytes: available)
            }
        }
        guard let owner else {
            for id in order { try check(id, others: 0) }
            return
        }
        try ledger.reserve(totals.mapValues(\.bytes), order: order, for: owner, check: { try check($0, others: $1) })
    }

    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : sum
    }
}
