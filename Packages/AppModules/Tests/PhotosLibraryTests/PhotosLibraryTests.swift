import AppCore
import CoreGraphics
import Foundation
import LocalLibrary
import Testing

@testable import PhotosLibrary

enum Samples {
    static func asset(
        id: String = "6F1B8A2C-1D3E-4F5A-9B7C-0E2D4F6A8B1C/L0/001", width: Double = 1920, height: Double = 1080,
        subtypes: PhotoSubtypes = [], hasAdjustments: Bool = false, byteSize: Int64? = 12_345_678
    ) -> PhotoAsset {
        PhotoAsset(
            id: id, creationDate: Date(timeIntervalSince1970: 1_750_000_000),
            location: PhotoLocation(latitude: 48.85, longitude: 2.35, altitude: 35),
            pixelSize: CGSize(width: width, height: height), duration: 12.5, hasAdjustments: hasAdjustments,
            subtypes: subtypes, originalFileName: "IMG_4211.MOV", originalByteSize: byteSize, isLocallyAvailable: true)
    }
}

@Suite struct PhotoItemBuilderTests {
    @Test func plainVideoHasNoBadges() {
        #expect(PhotoItemBuilder.build(Samples.asset()).badges.isEmpty)
    }

    @Test(arguments: [
        (PhotoSubtypes.cinematic, MediaBadge.cinematic),
        (PhotoSubtypes.highFrameRate, MediaBadge.sloMo),
        (PhotoSubtypes.spatial, MediaBadge.spatial),
    ])
    func subtypeMapsToBadge(subtype: PhotoSubtypes, badge: MediaBadge) {
        #expect(PhotoItemBuilder.build(Samples.asset(subtypes: subtype)).badges == [badge])
    }

    @Test func timelapseAndStreamedGetNoBadge() {
        #expect(PhotoItemBuilder.build(Samples.asset(subtypes: [.timelapse, .streamed])).badges.isEmpty)
    }

    @Test func editedVideoIsBadgedEdited() {
        #expect(PhotoItemBuilder.build(Samples.asset(hasAdjustments: true)).badges == [.edited])
    }

    @Test func fourKInEitherOrientation() {
        #expect(PhotoItemBuilder.build(Samples.asset(width: 3840, height: 2160)).badges == [.k4])
        #expect(PhotoItemBuilder.build(Samples.asset(width: 2160, height: 3840)).badges == [.k4])
        #expect(PhotoItemBuilder.build(Samples.asset(width: 2560, height: 1440)).badges.isEmpty)
        #expect(PhotoItemBuilder.build(Samples.asset(width: 3840, height: 1600)).badges.isEmpty)
    }

    @Test func combinedSubtypesGiveEveryBadge() {
        let asset = Samples.asset(
            width: 3840, height: 2160, subtypes: [.cinematic, .highFrameRate, .spatial], hasAdjustments: true)
        #expect(PhotoItemBuilder.build(asset).badges == [.cinematic, .sloMo, .spatial, .edited, .k4])
    }

    @Test func itemCopiesFieldsAndLeavesUnknownsEmpty() {
        let asset = Samples.asset(subtypes: .highFrameRate)
        let item = PhotoItemBuilder.build(asset)
        #expect(item.byteSize == 12_345_678)
        #expect(item.duration == 12.5)
        #expect(item.pixelSize == CGSize(width: 1920, height: 1080))
        #expect(item.frameRate == 0)
        #expect(item.captureDate == asset.creationDate)
        #expect(item.isAvailable)
        #expect(item.inventory == MetadataInventory())
        #expect(item.source == .photos(asset.id))
        #expect(item.photosIdentifier == asset.id)
        #expect(item.name == "IMG_4211.MOV")
        // A Photos video has no file location, so nothing can build a path from it.
        #expect(item.fileURL == nil)
    }

    @Test func unknownSizeIsZero() {
        #expect(PhotoItemBuilder.build(Samples.asset(byteSize: nil)).byteSize == 0)
    }

    @Test func idIsStablePerIdentifier() {
        let first = PhotoItemBuilder.build(Samples.asset(id: "A/L0/001"))
        let again = PhotoItemBuilder.build(Samples.asset(id: "A/L0/001", byteSize: 1))
        let other = PhotoItemBuilder.build(Samples.asset(id: "B/L0/001"))
        #expect(first.id == again.id)
        #expect(first.id != other.id)
    }

    @Test func idCarriesVersionAndVariantBits() {
        let uuid = PhotoItemBuilder.itemID(for: "A/L0/001").uuid
        #expect(uuid.6 >> 4 == 8)
        #expect(uuid.8 >> 6 == 0b10)
    }
}

@Suite struct FakePhotoStoreTests {
    @Test func requestGrantsWhenNotDetermined() async {
        let store = FakePhotoStore(authorization: .notDetermined)
        store.authorizationOnRequest = .limited
        #expect(await store.authorization() == .notDetermined)
        #expect(await store.requestAuthorization() == .limited)
        #expect(await store.authorization() == .limited)
        #expect(store.requestCount == 1)
    }

    @Test func requestDoesNotChangeAnAnswerGiven() async {
        let store = FakePhotoStore(authorization: .denied)
        #expect(await store.requestAuthorization() == .denied)
    }

    @Test func videosNeedAccess() async throws {
        let store = FakePhotoStore(assets: [Samples.asset()], authorization: .denied)
        await #expect(throws: PhotoStoreError.notAuthorized) { try await store.videos() }
        store.currentAuthorization = .limited
        #expect(try await store.videos().map(\.id) == [Samples.asset().id])
    }

    @Test func albumsOfAMissingAssetThrow() async throws {
        let asset = Samples.asset()
        let store = FakePhotoStore(assets: [asset])
        store.albums = [asset.id: ["album-1"]]
        #expect(try await store.albums(containing: asset.id) == ["album-1"])
        await #expect(throws: PhotoStoreError.notInLibrary("gone")) { try await store.albums(containing: "gone") }
    }

    @Test func changeStreamEmitsAndUnsubscribes() async {
        let store = FakePhotoStore()
        var stream: AsyncStream<Void>? = store.changes()
        #expect(store.subscriberCount == 1)
        var iterator = stream?.makeAsyncIterator()
        store.emitChange()
        let change: Void? = await iterator?.next()
        #expect(change != nil)
        stream = nil
        iterator = nil
        #expect(store.subscriberCount == 0)
    }
}
