import Foundation
import Synchronization

/// An original Photos video that a Replace has made redundant: its converted copy is saved and verified, and the
/// original waits for the batch delete that moves it to Recently Deleted.
public struct PendingDeletion: Codable, Sendable, Equatable, Hashable {
    /// The original's local identifier.
    public let assetID: String
    /// The job that produced the copy, so its outcome can be updated once the delete happened.
    public let jobID: UUID
    /// The copy's local identifier.
    public let replacedBy: String

    public init(assetID: String, jobID: UUID, replacedBy: String) {
        self.assetID = assetID
        self.jobID = jobID
        self.replacedBy = replacedBy
    }
}

/// The originals waiting for the batch delete, kept in a JSON file so they survive a relaunch. Nothing in here
/// deletes anything: the app asks Photos to delete them, once, after the queue finishes (the user confirms).
public final class PendingDeletions: Sendable {
    private struct State {
        var entries: [PendingDeletion]
        /// The file was there but couldn't be read: it is set aside before the first save writes over it.
        var unreadableFileToSetAside: Bool
    }

    private let fileURL: URL
    private let state: Mutex<State>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        var entries: [PendingDeletion] = []
        var unreadable = false
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([PendingDeletion].self, from: data) {
                entries = decoded
            } else {
                unreadable = true
            }
        }
        state = Mutex(State(entries: entries, unreadableFileToSetAside: unreadable))
    }

    /// `<directory>/pending-deletions.json`.
    public convenience init(directory: URL) {
        self.init(fileURL: directory.appending(path: "pending-deletions.json", directoryHint: .notDirectory))
    }

    public var all: [PendingDeletion] { state.withLock { $0.entries } }

    /// Records an original. An original already recorded is replaced (it has only one copy to wait for).
    public func add(assetID: String, jobID: UUID, replacedBy: String) {
        state.withLock { state in
            state.entries.removeAll { $0.assetID == assetID }
            state.entries.append(PendingDeletion(assetID: assetID, jobID: jobID, replacedBy: replacedBy))
            save(&state)
        }
    }

    /// Forgets originals, for example after they were deleted.
    public func remove(assetIDs: some Collection<String>) {
        state.withLock { state in
            let before = state.entries.count
            state.entries.removeAll { assetIDs.contains($0.assetID) }
            if state.entries.count != before { save(&state) }
        }
    }

    private func save(_ state: inout State) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if state.unreadableFileToSetAside {
            let aside = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            state.unreadableFileToSetAside = false
        }
        guard let data = try? JSONEncoder().encode(state.entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
