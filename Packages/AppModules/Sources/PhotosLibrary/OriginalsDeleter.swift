import Foundation

/// What one batch delete did.
public struct OriginalsDeletion: Sendable, Equatable {
    /// Originals that were in a delete call that succeeded and are no longer found.
    public var moved: [PendingDeletion] = []
    /// Originals that were already gone from the library (full access only); nothing was deleted for them.
    public var alreadyGone: [PendingDeletion] = []
    /// Originals that Photos still returns after the delete; they stay pending.
    public var kept: [PendingDeletion] = []
    /// Originals left out of the batch, each with the reason; they stay pending until the user removes them.
    public var blocked: [(entry: PendingDeletion, reason: PendingBlock)] = []

    public init(
        moved: [PendingDeletion] = [], alreadyGone: [PendingDeletion] = [], kept: [PendingDeletion] = [],
        blocked: [(entry: PendingDeletion, reason: PendingBlock)] = []
    ) {
        self.moved = moved
        self.alreadyGone = alreadyGone
        self.kept = kept
        self.blocked = blocked
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.moved == rhs.moved && lhs.alreadyGone == rhs.alreadyGone && lhs.kept == rhs.kept
            && lhs.blocked.map(\.entry) == rhs.blocked.map(\.entry)
            && lhs.blocked.map(\.reason) == rhs.blocked.map(\.reason)
    }
}

/// Moves the pending originals to Recently Deleted in one delete, which Photos asks the user to confirm once.
///
/// Pending originals can wait for days, so just before the delete each one is checked again: its shrunk copy must
/// still be in the library, and the original must still be as it was when the copy was verified. An original that
/// fails is left out and stays pending with a reason. Under limited access an original that can't be fetched is not
/// known to be gone, so it is kept and never dropped. "Moved" rests on an id being in a delete call that succeeded
/// and no longer fetching: PhotoKit can't list Recently Deleted.
public enum OriginalsDeleter {
    /// Checks every pending original, then deletes the ones that pass, once.
    ///
    /// - Returns: what happened to each original. Originals that were moved or already gone are removed from
    ///   `pending`; the rest stay, the blocked ones with their reason recorded.
    /// - Throws: `CancellationError` when the user declines the system confirmation (nothing is deleted and
    ///   `pending` is unchanged apart from recorded reasons), or the store's error when Photos refuses.
    public static func deleteAll(store: any PhotoStore, pending: PendingDeletions) async throws -> OriginalsDeletion {
        let limited = await store.authorization() == .limited
        var result = OriginalsDeletion()
        var ready: [PendingDeletion] = []
        for entry in pending.all {
            switch await check(entry, in: store, limited: limited) {
            case .ready: ready.append(entry)
            case .gone: result.alreadyGone.append(entry)
            case .blocked(let reason): result.blocked.append((entry, reason))
            }
        }
        for entry in pending.all where !result.blocked.contains(where: { $0.entry.assetID == entry.assetID }) {
            pending.setBlock(nil, forAsset: entry.assetID)
        }
        for (entry, reason) in result.blocked { pending.setBlock(reason, forAsset: entry.assetID) }

        // An id that vanishes between the check and the call makes Photos refuse the whole call. Then everything
        // left is checked again, so nothing unchecked is sent, and the call is made once more.
        var attempt = 0
        while !ready.isEmpty {
            try Task.checkCancellation()
            do {
                try await store.deleteAssets(ids: ready.map(\.assetID))
                break
            } catch PhotoStoreError.notInLibrary(let missing) where attempt == 0 {
                attempt += 1
                var stillReady: [PendingDeletion] = []
                for entry in ready {
                    switch await check(entry, in: store, limited: limited) {
                    case .ready: stillReady.append(entry)
                    case .gone: result.alreadyGone.append(entry)
                    case .blocked(let reason):
                        result.blocked.append((entry, reason))
                        pending.setBlock(reason, forAsset: entry.assetID)
                    }
                }
                // Photos named an id that the checks still see: not a vanished one, so nothing is retried.
                guard stillReady.count < ready.count else { throw PhotoStoreError.notInLibrary(missing) }
                ready = stillReady
            }
        }
        for entry in ready {
            if await isGone(entry.assetID, in: store) { result.moved.append(entry) } else { result.kept.append(entry) }
        }
        pending.remove(assetIDs: (result.moved + result.alreadyGone).map(\.assetID))
        return result
    }

    private enum Check {
        case ready
        case gone
        case blocked(PendingBlock)
    }

    private static func check(_ entry: PendingDeletion, in store: any PhotoStore, limited: Bool) async -> Check {
        // Without what the original looked like when the copy was verified (and which copy that was), nothing can
        // say it is unchanged, so it never goes in a batch.
        guard entry.hasBaseline, !entry.replacedBy.isEmpty else { return .blocked(.noBaseline) }
        let original: PhotoAsset
        do {
            original = try await store.asset(id: entry.assetID)
        } catch PhotoStoreError.notInLibrary {
            return limited ? .blocked(.limitedAccess) : .gone
        } catch {
            return .blocked(.unchecked)
        }
        // Any change counts, a trim or an edit as well as a caption or a favourite: the date is the safe check.
        if original.modificationDate != entry.originalModified
            || original.hasAdjustments != entry.originalHadAdjustments
        {
            return .blocked(.originalChanged)
        }
        do {
            _ = try await store.asset(id: entry.replacedBy)
        } catch PhotoStoreError.notInLibrary {
            return .blocked(.copyMissing)
        } catch {
            return .blocked(.unchecked)
        }
        return .ready
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
