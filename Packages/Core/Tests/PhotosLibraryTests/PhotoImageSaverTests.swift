import AppCore
import CoreGraphics
import Foundation
import Testing

@testable import PhotosLibrary

@Suite struct PhotoImageSaverTests {
    @Test func photosLibraryLoadsImagesAndLivePhotosAlongsideVideos() async throws {
        let image = PhotoAsset(
            id: "img-1", mediaKind: .image, pixelSize: CGSize(width: 4032, height: 3024),
            subtypes: [.livePhoto, .depthEffect, .hdrPhoto], originalFileName: "IMG_0001.HEIC",
            originalByteSize: 2_500_000, pairedVideoByteSize: 3_100_000)
        let raw = PhotoAsset(
            id: "img-2", mediaKind: .image, pixelSize: CGSize(width: 8064, height: 6048),
            subtypes: [.rawPhoto], originalFileName: "IMG_0002.DNG",
            originalByteSize: 48_000_000)
        let video = PhotoAsset(
            id: "vid-1", mediaKind: .video, pixelSize: CGSize(width: 3840, height: 2160),
            duration: 12, subtypes: [.highFrameRate], originalFileName: "IMG_0003.MOV",
            originalByteSize: 80_000_000)

        let store = FakePhotoStore(assets: [image, raw, video])
        let library = await PhotosLibrary(store: store, loadIndex: { ([:], .notFound) })
        await library.start()
        await library.waitUntilIdle()

        let items = await library.items
        #expect(items.count == 3)
        let liveItem = try #require(items.first { $0.name == "IMG_0001.HEIC" })
        #expect(liveItem.isImage)
        #expect(liveItem.badges == [.livePhoto, .portrait, .hdr])

        let rawItem = try #require(items.first { $0.name == "IMG_0002.DNG" })
        #expect(rawItem.badges == [.raw])
    }

    @Test func saverSavesVerifiedLivePhotoAndStillImage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "photo-image-saver-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let still = dir.appending(path: "still.heic")
        let paired = dir.appending(path: "paired.mov")
        try Data("still-bytes".utf8).write(to: still)
        try Data("video-bytes".utf8).write(to: paired)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = PhotoAsset(
            id: "live-src", mediaKind: .image, creationDate: date,
            location: PhotoLocation(latitude: 37.3349, longitude: -122.0090),
            pixelSize: CGSize(width: 4032, height: 3024), isFavorite: true,
            subtypes: [.livePhoto], originalFileName: "IMG_1001.HEIC",
            originalByteSize: 3_000_000, pairedVideoByteSize: 2_500_000, caption: "Live sunset")

        let store = FakePhotoStore(assets: [source])
        store.existingAlbums = ["alb-1"]
        store.albums["live-src"] = ["alb-1"]
        store.savedPixelSize = CGSize(width: 2016, height: 1512)

        let saver = PhotoSaver(store: store)
        let savedID = try await saver.saveImage(
            file: still, pairedVideoFile: paired, like: source, albums: ["alb-1"],
            expectedPixelSize: CGSize(width: 2016, height: 1512))

        let saved = try await store.asset(id: savedID)
        #expect(saved.mediaKind == .image)
        #expect(saved.isLivePhoto)
        #expect(saved.caption == "Live sunset")
        #expect(store.saves.count == 1)
        #expect(store.saves[0].addedAlbums == ["alb-1"])

        // Verification refuses missing Live Photo subtype if paired video was dropped by store
        store.adjustSaved = { asset in
            PhotoAsset(
                id: asset.id, mediaKind: .image, creationDate: asset.creationDate, location: asset.location,
                pixelSize: asset.pixelSize, isFavorite: asset.isFavorite, isHidden: asset.isHidden,
                subtypes: [], originalFileName: asset.originalFileName,
                originalByteSize: asset.originalByteSize, caption: asset.caption)
        }
        await #expect(throws: PhotoSaveError.self) {
            _ = try await saver.saveImage(
                file: still, pairedVideoFile: paired, like: source, albums: ["alb-1"],
                expectedPixelSize: CGSize(width: 2016, height: 1512))
        }
        #expect(!store.deletedIDs.isEmpty)
    }

    @Test func fetcherFetchesLivePhotoPairedVideoAndMapsErrors() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "photo-image-fetch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcStill = dir.appending(path: "src.heic")
        let srcPaired = dir.appending(path: "src.mov")
        try Data("still".utf8).write(to: srcStill)
        try Data("paired".utf8).write(to: srcPaired)

        let asset = PhotoAsset(
            id: "lp-1", mediaKind: .image, pixelSize: CGSize(width: 4032, height: 3024),
            subtypes: [.livePhoto], originalFileName: "IMG_9001.HEIC", originalByteSize: 1_000)
        let store = FakePhotoStore(assets: [asset])
        store.originalFiles["lp-1"] = srcStill
        store.pairedVideoFiles["lp-1"] = srcPaired

        let work = dir.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let fetcher = PhotoInputFetcher(store: store)
        let fetchedStill = try await fetcher.fetch(id: "lp-1", into: work)
        let fetchedPaired = try await fetcher.fetchPairedVideo(id: "lp-1", into: work, asset: asset)

        #expect(try Data(contentsOf: fetchedStill.url) == Data("still".utf8))
        #expect(try Data(contentsOf: fetchedPaired) == Data("paired".utf8))
        #expect(fetchedPaired.lastPathComponent == "IMG_9001-paired.mov")
    }
}
