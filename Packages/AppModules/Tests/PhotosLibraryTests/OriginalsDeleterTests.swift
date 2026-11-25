import Foundation
import Testing

@testable import PhotosLibrary

@Suite struct OriginalsDeleterTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "OriginalsDeleterTests-\(UUID().uuidString)/pending.json")
    }

    private static let modified = Date(timeIntervalSince1970: 1_750_000_000)

    /// A library with each original and its copy, and every original recorded as pending.
    private func library(
        _ ids: [String], authorization: PhotoAuthorization = .authorized
    ) -> (FakePhotoStore, PendingDeletions, URL) {
        let url = file()
        let originals = ids.map { Samples.asset(id: $0, modified: Self.modified) }
        let copies = ids.map { Samples.asset(id: "new-\($0)") }
        let store = FakePhotoStore(assets: originals + copies, authorization: authorization)
        let pending = PendingDeletions(fileURL: url)
        for id in ids {
            pending.add(
                assetID: id, jobID: UUID(), replacedBy: "new-\(id)", originalModified: Self.modified,
                originalHadAdjustments: false)
        }
        return (store, pending, url)
    }

    private func cleanUp(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func oneDeleteCallMovesEveryPendingOriginalAndEmptiesTheList() async throws {
        let (store, pending, url) = library(["A", "B", "C"])
        defer { cleanUp(url) }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(result.moved.map(\.assetID) == ["A", "B", "C"])
        #expect(result.kept.isEmpty && result.blocked.isEmpty && result.alreadyGone.isEmpty)
        #expect(store.deletedIDs == ["A", "B", "C"])
        #expect(store.operations.filter { if case .delete = $0 { true } else { false } }.count == 1)
        #expect(pending.all.isEmpty)
        #expect(PendingDeletions(fileURL: url).all.isEmpty)
    }

    @Test func aDeclinedConfirmationKeepsTheListAndDeletesNothing() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { cleanUp(url) }
        store.deleteError = CancellationError()

        await #expect(throws: CancellationError.self) {
            _ = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        }

        #expect(store.deletedIDs.isEmpty)
        #expect(pending.all.map(\.assetID) == ["A", "B"])
        #expect(PendingDeletions(fileURL: url).all.map(\.assetID) == ["A", "B"])
        store.deleteError = nil
        let again = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        #expect(again.moved.count == 2)
        #expect(pending.all.isEmpty)
    }

    @Test func aDeclineDoesNotForgetOriginalsThatWereAlreadyGone() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { cleanUp(url) }
        store.assets.removeAll { $0.id == "A" }
        store.deleteError = CancellationError()

        await #expect(throws: CancellationError.self) {
            _ = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        }

        #expect(pending.all.map(\.assetID) == ["A", "B"])
    }

    @Test func aMissingCopyKeepsTheOriginalOutOfTheBatch() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { cleanUp(url) }
        store.assets.removeAll { $0.id == "new-A" }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(store.deletedIDs == ["B"])
        #expect(result.moved.map(\.assetID) == ["B"])
        #expect(result.blocked.map(\.entry.assetID) == ["A"])
        #expect(result.blocked.map(\.reason) == [.copyMissing])
        #expect(
            PendingBlock.copyMissing.message
                == "Kept the original because the shrunk copy is no longer in your library")
        // It stays pending with its reason, also after a relaunch.
        #expect(PendingDeletions(fileURL: url).all.map(\.blocked) == [.copyMissing])
    }

    @Test func anOriginalEditedAfterShrinkingIsKept() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { cleanUp(url) }
        store.assets = store.assets.map { asset in
            asset.id == "A" ? Samples.asset(id: "A", modified: Date()) : asset
        }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(store.deletedIDs == ["B"])
        #expect(result.blocked.map(\.reason) == [.originalEdited])
        #expect(pending.all.first?.blocked == .originalEdited)
        #expect(PendingBlock.originalEdited.message == "Kept the original because it was edited after shrinking")
    }

    @Test func anEditStateChangeAloneKeepsTheOriginal() async throws {
        let (store, pending, url) = library(["A"])
        defer { cleanUp(url) }
        store.assets = store.assets.map { asset in
            asset.id == "A" ? Samples.asset(id: "A", hasAdjustments: true, modified: Self.modified) : asset
        }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(store.deletedIDs.isEmpty)
        #expect(result.blocked.map(\.reason) == [.originalEdited])
    }

    @Test func aMixedBatchSendsOnlyTheValidOnesToPhotos() async throws {
        let (store, pending, url) = library(["A", "B", "C", "D"])
        defer { cleanUp(url) }
        store.assets.removeAll { $0.id == "new-A" }  // copy gone
        store.assets = store.assets.map { asset in
            asset.id == "B" ? Samples.asset(id: "B", modified: Date()) : asset  // edited
        }
        store.assets.removeAll { $0.id == "C" }  // the user deleted it themselves (full access)

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(store.deletedIDs == ["D"])
        #expect(result.moved.map(\.assetID) == ["D"])
        #expect(result.alreadyGone.map(\.assetID) == ["C"])
        #expect(Set(result.blocked.map(\.entry.assetID)) == ["A", "B"])
        #expect(Set(pending.all.map(\.assetID)) == ["A", "B"])
    }

    @Test func underFullAccessAnOriginalThatCantBeFetchedIsGone() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { cleanUp(url) }
        store.assets.removeAll { $0.id == "A" }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(result.alreadyGone.map(\.assetID) == ["A"])
        #expect(result.moved.map(\.assetID) == ["B"])
        #expect(store.deletedIDs == ["B"])
        #expect(pending.all.isEmpty)
    }

    @Test func underLimitedAccessAnOriginalThatCantBeFetchedIsKeptNotDropped() async throws {
        let (store, pending, url) = library(["A", "B"], authorization: .limited)
        defer { cleanUp(url) }
        store.assets.removeAll { $0.id == "A" }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(result.alreadyGone.isEmpty)
        #expect(result.blocked.map(\.reason) == [.limitedAccess])
        #expect(result.moved.map(\.assetID) == ["B"])
        #expect(store.deletedIDs == ["B"])
        #expect(pending.all.map(\.assetID) == ["A"])
        #expect(pending.all.first?.blocked == .limitedAccess)
        #expect(PendingBlock.limitedAccess.message == "Can't see this original with limited Photos access")
        #expect(PendingBlock.limitedAccess.canBeRetried)
    }

    @Test func aLimitedAccessBlockLiftsWhenTheOriginalCanBeSeenAgain() async throws {
        let (store, pending, url) = library(["A"], authorization: .limited)
        defer { cleanUp(url) }
        let original = try #require(store.assets.first { $0.id == "A" })
        store.assets.removeAll { $0.id == "A" }
        _ = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        #expect(pending.all.first?.blocked == .limitedAccess)

        store.assets.append(original)
        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(result.moved.map(\.assetID) == ["A"])
        #expect(pending.all.isEmpty)
    }

    @Test func anOriginalThatVanishesBeforeTheCallDoesNotFailTheBatch() async throws {
        let (store, pending, url) = library(["A", "B"])
        defer { cleanUp(url) }
        // Both are seen by the checks; A is gone by the time of the call.
        store.beforeDelete = { [store] in store.assets.removeAll { $0.id == "A" } }

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        #expect(result.moved.map(\.assetID) == ["B"])
        #expect(result.alreadyGone.map(\.assetID) == ["A"])
        #expect(pending.all.isEmpty)
    }

    @Test func aRefusalFromPhotosKeepsTheListAndIsReported() async throws {
        let (store, pending, url) = library(["A"])
        defer { cleanUp(url) }
        store.deleteError = PhotoStoreError.notAuthorized

        await #expect(throws: PhotoStoreError.notAuthorized) {
            _ = try await OriginalsDeleter.deleteAll(store: store, pending: pending)
        }
        #expect(pending.all.map(\.assetID) == ["A"])
    }

    @Test func nothingPendingMakesNoDeleteCall() async throws {
        let url = file()
        defer { cleanUp(url) }
        let store = FakePhotoStore(assets: [])

        let result = try await OriginalsDeleter.deleteAll(store: store, pending: PendingDeletions(fileURL: url))

        #expect(result == OriginalsDeletion())
        #expect(!store.operations.contains { if case .delete = $0 { true } else { false } })
    }

    @Test func removingFromTheListDeletesNothing() async throws {
        let (store, pending, url) = library(["A"])
        defer { cleanUp(url) }
        store.assets.removeAll { $0.id == "new-A" }
        _ = try await OriginalsDeleter.deleteAll(store: store, pending: pending)

        pending.remove(assetIDs: ["A"])

        #expect(pending.all.isEmpty)
        #expect(store.deletedIDs.isEmpty)
        #expect(store.assets.contains { $0.id == "A" })
    }
}
