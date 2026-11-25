import Foundation

/// What one batch delete did.
public struct OriginalsDeletion: Sendable, Equatable {
    /// Originals that are gone from the library: deleted now, or already deleted by the user in Photos.
    public var moved: [PendingDeletion] = []
    /// Originals that Photos still returns after the delete; they stay pending.
    public var kept: [PendingDeletion] = []

    public init(moved: [PendingDeletion] = [], kept: [PendingDeletion] = []) {
        self.moved = moved
        self.kept = kept
    }
}

/// Moves the pending originals to Recently Deleted in one delete, which Photos asks the user to confirm once.
///
/// The claim "moved to Recently Deleted" rests on the delete succeeding and the id no longer fetching: PhotoKit
/// can't list Recently Deleted.
public enum OriginalsDeleter {
    /// Deletes every original in `pending`, once.
    ///
    /// - Returns: what happened to each original. Those that are gone are removed from `pending`; the rest stay.
    /// - Throws: `CancellationError` when the user declines the system confirmation (nothing is deleted and
    ///   `pending` is unchanged), or the store's error when Photos refuses; `pending` is unchanged then too.
    public static func deleteAll(store: any PhotoStore, pending: PendingDeletions) async throws -> OriginalsDeletion {
        let entries = pending.all
        var result = OriginalsDeletion()
        // An original the user already deleted in Photos needs no delete: it is gone, which is the goal.
        var present: [PendingDeletion] = []
        for entry in entries {
            if await isGone(entry.assetID, in: store) { result.moved.append(entry) } else { present.append(entry) }
        }
        pending.remove(assetIDs: result.moved.map(\.assetID))

        if !present.isEmpty {
            try Task.checkCancellation()
            try await store.deleteAssets(ids: present.map(\.assetID))
            for entry in present {
                if await isGone(entry.assetID, in: store) {
                    result.moved.append(entry)
                } else {
                    result.kept.append(entry)
                }
            }
            pending.remove(assetIDs: present.map(\.assetID).filter { id in result.moved.contains { $0.assetID == id } })
        }
        return result
    }

    private static func isGone(_ id: String, in store: any PhotoStore) async -> Bool {
        do {
            _ = try await store.asset(id: id)
            return false
        } catch PhotoStoreError.notInLibrary {
            return true
        } catch {
            return false
        }
    }
}
