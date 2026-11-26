import AppCore
import Foundation
import Synchronization

/// Why an original is not moved to Recently Deleted for now. It stays on the list until the user removes it.
public enum PendingBlock: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// The shrunk copy is no longer in the library.
    case copyMissing
    /// The original changed (edited, trimmed, or its details changed) after it was shrunk.
    case originalChanged = "originalEdited"
    /// Photos access is limited and the original can't be seen.
    case limitedAccess
    /// Photos couldn't say.
    case unchecked
    /// The record has no baseline to check the original against (an entry from an older version).
    case noBaseline

    /// What the bar and the job say, in a sentence.
    public var message: String {
        switch self {
        case .copyMissing: "Kept the original because the shrunk copy is no longer in your library"
        case .originalChanged: "Kept the original because it changed after shrinking"
        case .limitedAccess: "Can't see this original with limited Photos access"
        case .unchecked: "Kept the original because it couldn't be checked"
        case .noBaseline: "Kept the original because it couldn't be checked. Shrink it again to replace it."
        }
    }

    /// Whether looking again later (after a change in System Settings, say) can lift the block.
    public var canBeRetried: Bool { self == .limitedAccess || self == .unchecked }
}

/// An original Photos video that a Replace has made redundant: its converted copy is saved and verified, and the
/// original waits for the batch delete that moves it to Recently Deleted.
public struct PendingDeletion: Codable, Sendable, Equatable, Hashable {
    /// The original's local identifier.
    public let assetID: String
    /// The job that produced the copy, so its outcome can be updated once the delete happened.
    public let jobID: UUID
    /// The copy's local identifier.
    public let replacedBy: String
    /// How the original looked when the copy was made and verified. A change since then keeps it from being deleted.
    /// Nil `originalModified` with no recorded baseline (`hasBaseline` false) skips that check (older records).
    public let originalModified: Date?
    public let originalHadAdjustments: Bool
    public let hasBaseline: Bool
    /// Set when the last check kept this original out of the batch.
    public var blocked: PendingBlock?

    public init(
        assetID: String, jobID: UUID, replacedBy: String, originalModified: Date? = nil,
        originalHadAdjustments: Bool = false, hasBaseline: Bool = true, blocked: PendingBlock? = nil
    ) {
        self.assetID = assetID
        self.jobID = jobID
        self.replacedBy = replacedBy
        self.originalModified = originalModified
        self.originalHadAdjustments = originalHadAdjustments
        self.hasBaseline = hasBaseline
        self.blocked = blocked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        replacedBy = try container.decode(String.self, forKey: .replacedBy)
        originalModified = try container.decodeIfPresent(Date.self, forKey: .originalModified)
        originalHadAdjustments = try container.decodeIfPresent(Bool.self, forKey: .originalHadAdjustments) ?? false
        hasBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasBaseline) ?? false
        blocked = try container.decodeIfPresent(String.self, forKey: .blocked).map {
            PendingBlock(rawValue: $0) ?? .unchecked
        }
    }
}

/// "The copy of this job's video is saved in Photos as `newID`": written the moment the copy is saved and checked,
/// before anything else happens. A job that is put back in the queue after a crash or a quit finds it and carries
/// on from there (it never saves a second copy).
public struct SavedCopy: Codable, Sendable, Equatable {
    public let jobID: UUID
    /// The original's local identifier.
    public let originalID: String
    /// The copy's local identifier.
    public let newID: String
    /// What the job reports for the copy, before any Replace step.
    public var outcome: JobOutcome
    /// How the original looked when the copy was made from it: a change since then keeps it off the delete list.
    public let originalModified: Date?
    public let originalHadAdjustments: Bool
    /// The copy of the original in the originals folder, once it is written, so a second attempt doesn't write
    /// another one.
    public var backup: URL?

    public init(
        jobID: UUID, originalID: String, newID: String, outcome: JobOutcome, originalModified: Date?,
        originalHadAdjustments: Bool, backup: URL? = nil
    ) {
        self.jobID = jobID
        self.originalID = originalID
        self.newID = newID
        self.outcome = outcome
        self.originalModified = originalModified
        self.originalHadAdjustments = originalHadAdjustments
        self.backup = backup
    }
}

/// The originals waiting for the batch delete, and the copies saved by jobs still in the queue, kept in a JSON file
/// so they survive a relaunch. Nothing in here deletes anything: the app asks Photos to delete the originals, once,
/// after the queue finishes or when the user asks (the user confirms).
public final class PendingDeletions: Sendable {
    private struct State {
        var pending: [PendingDeletion]
        var saved: [SavedCopy]
        /// The file was there but couldn't be read: it is set aside before the first save writes over it.
        var unreadableFileToSetAside: Bool
    }

    /// The file's content.
    private struct Stored: Codable {
        var pending: [PendingDeletion]
        var saved: [SavedCopy]
    }

    private let fileURL: URL
    private let state: Mutex<State>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        var stored = Stored(pending: [], saved: [])
        var unreadable = false
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            if let decoded = try? decoder.decode(Stored.self, from: data) {
                stored = decoded
            } else if let legacy = try? decoder.decode([PendingDeletion].self, from: data) {
                stored.pending = legacy
            } else {
                unreadable = true
            }
        }
        state = Mutex(State(pending: stored.pending, saved: stored.saved, unreadableFileToSetAside: unreadable))
    }

    /// `<directory>/pending-deletions.json`.
    public convenience init(directory: URL) {
        self.init(fileURL: directory.appending(path: "pending-deletions.json", directoryHint: .notDirectory))
    }

    /// The originals waiting, in the order they were recorded.
    public var all: [PendingDeletion] { state.withLock { $0.pending } }

    /// Records an original. An original already recorded is replaced (it has only one copy to wait for).
    public func add(
        assetID: String, jobID: UUID, replacedBy: String, originalModified: Date? = nil,
        originalHadAdjustments: Bool = false
    ) {
        state.withLock { state in
            state.pending.removeAll { $0.assetID == assetID }
            state.pending.append(
                PendingDeletion(
                    assetID: assetID, jobID: jobID, replacedBy: replacedBy, originalModified: originalModified,
                    originalHadAdjustments: originalHadAdjustments))
            save(&state)
        }
    }

    /// Sets (or clears) why an original is kept out of the batch.
    public func setBlock(_ block: PendingBlock?, forAsset assetID: String) {
        state.withLock { state in
            guard let index = state.pending.firstIndex(where: { $0.assetID == assetID }),
                state.pending[index].blocked != block
            else { return }
            state.pending[index].blocked = block
            save(&state)
        }
    }

    /// Forgets originals, for example after they were deleted.
    public func remove(assetIDs: some Collection<String>) {
        state.withLock { state in
            let before = state.pending.count
            state.pending.removeAll { assetIDs.contains($0.assetID) }
            if state.pending.count != before { save(&state) }
        }
    }

    // MARK: - Saved copies

    /// The copy a job saved, if it did.
    public func savedCopy(for jobID: UUID) -> SavedCopy? {
        state.withLock { $0.saved.first { $0.jobID == jobID } }
    }

    /// Notes that a job's copy is saved and checked.
    public func markSaved(_ copy: SavedCopy) {
        state.withLock { state in
            state.saved.removeAll { $0.jobID == copy.jobID }
            state.saved.append(copy)
            save(&state)
        }
    }

    /// Forgets one job's saved copy, for example when the copy is gone from Photos.
    public func forgetSavedCopy(forJob jobID: UUID) {
        state.withLock { state in
            let before = state.saved.count
            state.saved.removeAll { $0.jobID == jobID }
            if state.saved.count != before { save(&state) }
        }
    }

    /// Sets (or clears) where the job's copy of the original was written.
    public func setBackup(_ url: URL?, forJob jobID: UUID) {
        state.withLock { state in
            guard let index = state.saved.firstIndex(where: { $0.jobID == jobID }) else { return }
            state.saved[index].backup = url
            save(&state)
        }
    }

    /// Forgets the saved copies of jobs that are not in `jobIDs`: once a job has finished (or left the queue) there
    /// is nothing to resume.
    public func keepSavedCopies(forJobs jobIDs: Set<UUID>) {
        state.withLock { state in
            let before = state.saved.count
            state.saved.removeAll { !jobIDs.contains($0.jobID) }
            if state.saved.count != before { save(&state) }
        }
    }

    // MARK: - File

    private func save(_ state: inout State) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if state.unreadableFileToSetAside {
            let aside = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            state.unreadableFileToSetAside = false
        }
        guard let data = try? JSONEncoder().encode(Stored(pending: state.pending, saved: state.saved)) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
