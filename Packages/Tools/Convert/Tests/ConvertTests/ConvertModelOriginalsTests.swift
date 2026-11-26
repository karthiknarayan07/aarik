import AppCore
import AppServices
import AppUI
import Foundation
import PhotosLibrary
import SwiftUI
import Testing

@testable import Convert
@testable import ConvertUI

@MainActor
@Suite struct ConvertModelOriginalsTests {
    private static let modified = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(
            path: "convert-originals-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRig(
        assetIDs: [String], authorization: PhotoAuthorization = .authorized, directory: URL
    ) -> (model: ConvertModel, store: FakePhotoStore) {
        let originals = assetIDs.map { id in
            PhotoAsset(
                id: id, creationDate: Self.modified, location: nil, pixelSize: CGSize(width: 3840, height: 2160),
                duration: 10, originalFileName: "\(id).MOV", originalByteSize: 10_000,
                modificationDate: Self.modified)
        }
        let copies = assetIDs.map { id in
            PhotoAsset(
                id: "new-\(id)", creationDate: Self.modified, location: nil,
                pixelSize: CGSize(width: 1920, height: 1080), duration: 10, originalFileName: "new-\(id).MOV",
                originalByteSize: 4_000, modificationDate: Self.modified)
        }
        let store = FakePhotoStore(assets: originals + copies, authorization: authorization)
        let suite = UserDefaults(suiteName: "ConvertModelOriginalsTests-\(UUID().uuidString)")!
        let services = AppServices(directory: directory, defaults: suite, photoStore: store)
        for id in assetIDs {
            services.pendingDeletions.add(
                assetID: id, jobID: UUID(), replacedBy: "new-\(id)", originalModified: Self.modified,
                originalHadAdjustments: false)
        }
        let model = ConvertModel(services: services)
        return (model, store)
    }

    private func deleteCallCount(_ store: FakePhotoStore) -> Int {
        store.operations.count {
            if case .delete = $0 { return true }
            return false
        }
    }

    @Test func pendingBarUsesSingularAndPluralTitlesWithEllipsis() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (singleModel, _) = makeRig(assetIDs: ["A"], directory: directory)
        #expect(singleModel.pendingDeletionBar?.countedActionTitle == "Move 1 Original to Recently Deleted…")

        let (multiModel, _) = makeRig(assetIDs: ["A", "B", "C"], directory: directory)
        #expect(multiModel.pendingDeletionBar?.countedActionTitle == "Move 3 Originals to Recently Deleted…")
    }

    @Test func backgroundStateHidesBarAndBlocksAutomaticAndManualDeletes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, store) = makeRig(assetIDs: ["A", "B"], directory: directory)

        model.isForeground = false

        #expect(model.pendingDeletionBar == nil)
        model.moveOriginalsAfterRun()
        model.moveOriginalsToRecentlyDeleted()
        model.performPendingDeletionAction()
        await model.moveOriginalsNow()

        #expect(deleteCallCount(store) == 0)
        #expect(store.deletedIDs.isEmpty)
        #expect(model.pendingOriginals.map(\.assetID) == ["A", "B"])

        // Returning to foreground reveals the accumulated pending originals without auto-deleting them.
        model.pendingDeletions.add(
            assetID: "C", jobID: UUID(), replacedBy: "new-C", originalModified: Self.modified,
            originalHadAdjustments: false)
        model.isForeground = true

        #expect(deleteCallCount(store) == 0)
        #expect(model.pendingDeletionBar?.countedActionTitle == "Move 3 Originals to Recently Deleted…")
        #expect(model.pendingDeletionBar?.status == .ready)
    }

    @Test func moveOriginalsUsesOneBatchAndDismissesMovedNotice() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, store) = makeRig(assetIDs: ["A", "B"], directory: directory)

        await model.moveOriginalsNow()

        #expect(deleteCallCount(store) == 1)
        #expect(store.deletedIDs == ["A", "B"])
        #expect(model.pendingOriginals.isEmpty)
        #expect(model.originalsNotice == .moved(count: 2))
        #expect(model.pendingDeletionBar?.countedActionTitle == "Done")

        model.performPendingDeletionAction()
        #expect(model.originalsNotice == nil)
        #expect(model.pendingDeletionBar == nil)
    }

    @Test func moveOriginalsRechecksEveryEntryAtDeleteTimeAndRemovesOnlyKeptWhenAsked() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, store) = makeRig(assetIDs: ["A", "B"], directory: directory)
        store.assets.removeAll { $0.id == "new-A" }

        await model.moveOriginalsNow()

        #expect(deleteCallCount(store) == 1)
        #expect(store.deletedIDs == ["B"])
        #expect(model.pendingOriginals.map(\.assetID) == ["A"])
        #expect(model.pendingOriginals.first?.blocked == .copyMissing)

        // Moved notice is shown first; dismissing "Done" reveals the kept original with Remove from List.
        #expect(model.originalsNotice == .moved(count: 1))
        #expect(model.pendingDeletionBar?.countedActionTitle == "Done")
        model.performPendingDeletionAction()

        #expect(model.originalsNotice == nil)
        #expect(model.pendingDeletionBar?.offersRemove == true)
        #expect(model.pendingDeletionBar?.countedActionTitle == nil)

        model.removeKeptOriginalsFromList()
        #expect(model.pendingOriginals.isEmpty)
        #expect(model.pendingDeletions.all.isEmpty)
        #expect(store.assets.contains { $0.id == "A" })
    }

    @Test func declinedConfirmationWaitsUntilExplicitActionOrNewOriginal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, store) = makeRig(assetIDs: ["A", "B"], directory: directory)
        store.deleteError = CancellationError()

        await model.moveOriginalsNow()

        #expect(model.originalsNotice == .declined)
        #expect(model.pendingOriginals.map(\.assetID) == ["A", "B"])
        #expect(model.pendingDeletionBar?.countedActionTitle == "Move 2 Originals to Recently Deleted…")

        // Automatic post-run check does not re-ask for already-declined originals.
        store.deleteError = nil
        model.moveOriginalsAfterRun()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(deleteCallCount(store) == 1)

        // User-triggered move retries once and moves the batch.
        await model.moveOriginalsNow()
        #expect(deleteCallCount(store) == 2)
        #expect(store.deletedIDs == ["A", "B"])
        #expect(model.pendingOriginals.isEmpty)
    }

    @Test func limitedAccessHoldOffersSettingsAndOpensHostSettings() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, store) = makeRig(assetIDs: ["A"], authorization: .limited, directory: directory)
        store.assets.removeAll { $0.id == "A" }
        var openedSettings = false
        model.host.openPhotosAccessSettings = { openedSettings = true }

        await model.moveOriginalsNow()

        let bar = try #require(model.pendingDeletionBar)
        #expect(bar.offersSettings)
        #expect(bar.offersRemove)
        #expect(bar.countedActionTitle == PendingDeletionBarContent.actionTitle)

        model.openPhotosAccessSettings()
        #expect(openedSettings)
    }

    #if os(iOS)
        @Test func iosPendingDeletionBarAndSceneWireToModel() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let (model, _) = makeRig(assetIDs: ["A", "B"], directory: directory)

            let bar = IOSPendingDeletionBar(model: model)
            let content = try #require(model.pendingDeletionBar)
            let card = IOSPendingDeletionBarContent(content: content, perform: model.performPendingDeletionAction)
            let scene = ConvertIOSScene(model: model)
            _ = bar.body
            _ = card.body
            _ = scene.destination(page: IOSPage.photos.rawValue)
        }
    #endif
}
