import CoreGraphics
import Foundation
import Testing

@testable import PhotosLibrary

@Suite struct PhotoSaverTests {
    private let target = CGSize(width: 1920, height: 1080)
    private let date = Date(timeIntervalSince1970: 1_623_758_400)
    private let place = PhotoLocation(latitude: 12.5, longitude: 45.25, altitude: 7)

    private func source(favorite: Bool = true, hidden: Bool = false) -> PhotoAsset {
        PhotoAsset(
            id: "src", creationDate: date, location: place, pixelSize: CGSize(width: 3840, height: 2160),
            duration: 10, isFavorite: favorite, isHidden: hidden, originalFileName: "IMG_1.MOV",
            originalByteSize: 5_000)
    }

    private func makeStore(albums: Set<String> = []) -> FakePhotoStore {
        let store = FakePhotoStore(assets: [source()])
        store.existingAlbums = albums
        return store
    }

    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "saver-\(UUID().uuidString).mov")
        try Data(repeating: 1, count: 64).write(to: url)
        return url
    }

    private func save(
        _ store: FakePhotoStore, like asset: PhotoAsset? = nil, albums: [String] = []
    ) async throws -> String {
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await PhotoSaver(store: store).save(
            file: url, like: asset ?? source(), albums: albums, expectedPixelSize: target)
    }

    private func verifyFailure(_ store: FakePhotoStore) async -> PhotoSaveError? {
        do {
            _ = try await save(store)
            return nil
        } catch {
            return error as? PhotoSaveError
        }
    }

    @Test func passesTheCopiedFieldsInOneSave() async throws {
        let store = makeStore()
        let id = try await save(store, like: source(favorite: true, hidden: true))
        #expect(store.saves.count == 1)
        let request = try #require(store.saves.first?.request)
        #expect(request.file.pathExtension == "mov")
        #expect(request.creationDate == date)
        #expect(request.location == place)
        #expect(request.isFavorite)
        #expect(request.isHidden)
        #expect(store.saves.first?.newID == id)
        #expect(try await store.asset(id: id).isFavorite)
    }

    @Test func addsOnlyToAlbumsThatStillExist() async throws {
        let store = makeStore(albums: ["a", "c"])
        let id = try await save(store, albums: ["a", "b", "c"])
        #expect(store.saves.first?.request.albums == ["a", "b", "c"])
        #expect(store.saves.first?.addedAlbums == ["a", "c"])
        #expect(try await store.albums(containing: id) == ["a", "c"])
    }

    @Test func albumsToAddKeepsRequestedOrderAndDropsMissingAndDuplicates() {
        let request = PhotoSaveRequest(
            file: URL(filePath: "/x.mov"), creationDate: nil, location: nil, isFavorite: false, isHidden: false,
            albums: ["a", "b", "c", "a"])
        #expect(request.albumsToAdd(existing: ["c", "a", "z"]) == ["a", "c"])
        #expect(request.albumsToAdd(existing: []) == [])
    }

    @Test(arguments: [PhotoAuthorization.authorized, .limited])
    func savesWhenAccessIsFullOrLimited(access: PhotoAuthorization) async throws {
        let store = makeStore()
        store.currentAuthorization = access
        _ = try await save(store)
        #expect(store.saves.count == 1)
    }

    @Test(arguments: [PhotoAuthorization.denied, .restricted, .notDetermined])
    func refusesToSaveWithoutAccess(access: PhotoAuthorization) async {
        let store = makeStore()
        store.currentAuthorization = access
        let error = await verifyFailure(store)
        guard case .saveFailed(let reason) = error else {
            Issue.record("expected saveFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == PhotoStoreError.notAuthorized.localizedDescription)
        #expect(store.assets.map(\.id) == ["src"])
    }

    @Test(arguments: [PhotoAuthorization.denied, .restricted, .notDetermined])
    func refusesToDeleteWithoutAccess(access: PhotoAuthorization) async {
        let store = makeStore()
        store.currentAuthorization = access
        await #expect(throws: PhotoStoreError.notAuthorized) { try await store.deleteAssets(ids: ["src"]) }
        #expect(store.deletedIDs.isEmpty)
    }

    @Test func deletingWhatIsNotThereIsReported() async {
        let store = makeStore()
        await #expect(throws: PhotoStoreError.notInLibrary("ghost")) {
            try await store.deleteAssets(ids: ["ghost"])
        }
        #expect(store.deletedIDs.isEmpty)
    }

    @Test func cleanupThatFindsNothingToDeleteIsNotClaimedAsRemoved() async {
        let store = makeStore()
        store.savedDuration = 99
        // Photos loses the new asset between the check and the delete.
        store.deleteError = PhotoStoreError.notInLibrary("new-1")
        guard case .verifyFailed(_, let cleanup)? = await verifyFailure(store) else {
            Issue.record("expected verifyFailed")
            return
        }
        #expect(cleanup == .notFound)
    }

    @Test func limitedAccessMayDelete() async throws {
        let store = makeStore()
        store.currentAuthorization = .limited
        try await store.deleteAssets(ids: ["src"])
        #expect(store.deletedIDs == ["src"])
    }

    @Test func dateWithinASecondAndSwappedOrientationVerify() async throws {
        let store = makeStore()
        store.savedPixelSize = CGSize(width: 1080, height: 1920)
        store.adjustSaved = { asset in
            PhotoAsset(
                id: asset.id, creationDate: asset.creationDate?.addingTimeInterval(0.4),
                location: asset.location, pixelSize: asset.pixelSize, duration: asset.duration,
                originalFileName: "x", originalByteSize: 1)
        }
        _ = try await save(store)
        #expect(store.deletedIDs.isEmpty)
    }

    @Test func dateTwoSecondsOffFails() async {
        let store = makeStore()
        store.adjustSaved = { asset in
            PhotoAsset(
                id: asset.id, creationDate: asset.creationDate?.addingTimeInterval(2),
                location: asset.location, pixelSize: asset.pixelSize, duration: asset.duration,
                originalFileName: "x", originalByteSize: 1)
        }
        guard case .verifyFailed? = await verifyFailure(store) else {
            Issue.record("expected verifyFailed")
            return
        }
    }

    @Test func missingPlaceholderIsReportedAsPossiblyAdded() async {
        let store = makeStore()
        store.saveError = .unavailable("Photos gave no identifier; a video may have been added")
        guard case .saveFailed(let reason) = await verifyFailure(store) else {
            Issue.record("expected saveFailed")
            return
        }
        #expect(reason.contains("may have been added"))
    }

    @Test func neverChangesTheSourceAsset() async throws {
        let store = makeStore(albums: ["a"])
        store.albums["src"] = ["a"]
        _ = try await save(store, albums: ["a"])
        #expect(store.assets.first { $0.id == "src" } == source())
        #expect(store.albums["src"] == ["a"])
        #expect(store.deletedIDs.isEmpty)
    }

    @Test func verifyIgnoresSubtypeBits() async throws {
        let store = makeStore()
        // The fake's new asset carries an unnamed subtype bit; the source has none, and it must still verify.
        let id = try await save(store)
        #expect(try await store.asset(id: id).subtypes != [])
        #expect(store.deletedIDs.isEmpty)
    }

    @Test func durationWithinToleranceVerifies() async throws {
        let store = makeStore()
        store.savedDuration = 10.09
        _ = try await save(store)
        #expect(store.deletedIDs.isEmpty)
    }

    @Test(arguments: ["duration", "size", "empty", "date", "location"])
    func mismatchRemovesTheNewAsset(kind: String) async throws {
        let store = makeStore()
        switch kind {
        case "duration": store.savedDuration = 10.5
        case "size": store.savedPixelSize = CGSize(width: 1280, height: 720)
        case "empty": store.savedByteSize = 0
        case "date":
            store.adjustSaved = { asset in
                PhotoAsset(
                    id: asset.id, creationDate: Date(timeIntervalSince1970: 5), location: asset.location,
                    pixelSize: asset.pixelSize, duration: asset.duration, originalFileName: "x",
                    originalByteSize: 1)
            }
        default:
            store.adjustSaved = { asset in
                PhotoAsset(
                    id: asset.id, creationDate: asset.creationDate, location: nil, pixelSize: asset.pixelSize,
                    duration: asset.duration, originalFileName: "x", originalByteSize: 1)
            }
        }
        let error = await verifyFailure(store)
        guard case .verifyFailed(let reasons, let cleanup) = error else {
            Issue.record("expected verifyFailed, got \(String(describing: error))")
            return
        }
        #expect(reasons.count == 1)
        #expect(cleanup == .removed)
        #expect(store.deletedIDs == ["new-1"])
        #expect(store.assets.map(\.id) == ["src"])
    }

    @Test func noFetchAfterTheDelete() async {
        let store = makeStore()
        store.savedDuration = 99
        _ = await verifyFailure(store)
        #expect(store.operations == [.save, .fetch("new-1"), .delete(["new-1"])])
    }

    @Test func declinedDeleteIsReported() async {
        let store = makeStore()
        store.savedDuration = 99
        store.deleteError = CancellationError()
        let error = await verifyFailure(store)
        guard case .verifyFailed(_, let cleanup) = error else {
            Issue.record("expected verifyFailed")
            return
        }
        #expect(cleanup == .declined)
        #expect(store.assets.map(\.id).contains("new-1"))
        #expect(error?.errorDescription?.contains("original is untouched") == true)
        #expect(store.operations.last == .delete(["new-1"]))
    }

    @Test func failedDeleteIsReported() async {
        let store = makeStore()
        store.savedDuration = 99
        store.deleteError = PhotoStoreError.unavailable("busy")
        let error = await verifyFailure(store)
        guard case .verifyFailed(_, .failed) = error else {
            Issue.record("expected a failed cleanup, got \(String(describing: error))")
            return
        }
    }

    @Test func saveFailureLeavesNoAssetAndDeletesNothing() async {
        let store = makeStore(albums: ["a"])
        store.saveError = .unavailable("disk full")
        let error = await verifyFailure(store)
        guard case .saveFailed = error else {
            Issue.record("expected saveFailed, got \(String(describing: error))")
            return
        }
        #expect(store.assets.map(\.id) == ["src"])
        #expect(store.saves.isEmpty)
        #expect(store.operations == [.save])
        #expect(store.albums.isEmpty)
    }

    @Test func cancelledBeforeSaveDoesNothing() async throws {
        let store = makeStore()
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PhotoSaver(store: store).save(
                file: url, like: source(), albums: [], expectedPixelSize: target)
        }
        await #expect(throws: PhotoSaveError.cancelled) { try await task.value }
        #expect(store.operations.isEmpty)
    }
}
