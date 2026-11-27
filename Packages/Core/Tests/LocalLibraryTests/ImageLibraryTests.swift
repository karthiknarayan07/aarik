import AppCore
import CoreGraphics
import Foundation
import MediaTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import LocalLibrary

@Suite struct ImageLibraryTests {
    @Test func scannerFindsImagesAndVideosAndReconstructsFromInventory() async throws {
        var heicOpts = ImageFixtureOptions()
        heicOpts.width = 1600
        heicOpts.height = 1200
        heicOpts.utType = .heic
        heicOpts.includeGainMap = true
        heicOpts.livePhotoContentID = "12345678-1234-1234-1234-1234567890AB"
        let heicURL = try ImageFixtureFactory.makeImage(heicOpts)
        let dir = heicURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        var pngOpts = ImageFixtureOptions()
        pngOpts.width = 400
        pngOpts.height = 400
        pngOpts.utType = .png
        pngOpts.withAlpha = true
        let pngTemp = try ImageFixtureFactory.makeImage(pngOpts)
        let pngURL = dir.appending(path: "transparent.png")
        try FileManager.default.moveItem(at: pngTemp, to: pngURL)
        try? FileManager.default.removeItem(at: pngTemp.deletingLastPathComponent())

        var clipOpts = ClipOptions()
        clipOpts.width = 640
        clipOpts.height = 360
        let clipTemp = try await FixtureFactory.makeClip(clipOpts)
        let clipURL = dir.appending(path: "clip.mov")
        try FileManager.default.moveItem(at: clipTemp, to: clipURL)
        try? FileManager.default.removeItem(at: clipTemp.deletingLastPathComponent())

        let scanner = LibraryScanner()
        let collected = Mutex<[ScannedFile]>([])
        await scanner.scan([dir]) { batch in
            collected.withLock { $0.append(contentsOf: batch) }
        }
        let found = collected.withLock { $0 }

        let images = found.map(\.item).filter(\.isImage)
        let videos = found.map(\.item).filter(\.isVideo)
        #expect(images.count == 2)
        #expect(videos.count == 1)

        let heic = try #require(images.first { $0.name == heicURL.lastPathComponent })
        #expect(heic.badges.contains(.hdr))
        #expect(heic.badges.contains(.livePhoto))
        #expect(heic.pixelSize == CGSize(width: 1600, height: 1200))

        let png = try #require(images.first { $0.name == "transparent.png" })
        #expect(png.badges.contains(.transparent))

        // Reconstruct from inventory (e.g. after app launch restore or moved bookmark)
        let rebuilt = try #require(
            LibraryItemBuilder.build(url: heicURL, inventory: heic.inventory, byteSize: heic.byteSize, id: heic.id))
        #expect(rebuilt.mediaKind == .image)
        #expect(rebuilt.badges == heic.badges)
        #expect(rebuilt.pixelSize == heic.pixelSize)
    }

    @MainActor
    @Test func mediaFilterAndImageFacetsFilterWithoutMixingVideoBuckets() throws {
        let collection = StaticCollection(items: [
            LibraryItem(
                id: UUID(), mediaKind: .image, url: URL(filePath: "/tmp/a.heic"), byteSize: 5_000_000,
                pixelSize: CGSize(width: 8064, height: 6048), captureDate: nil,
                badges: [.livePhoto, .hdr], isAvailable: true, inventory: MetadataInventory()),
            LibraryItem(
                id: UUID(), mediaKind: .image, url: URL(filePath: "/tmp/b.png"), byteSize: 900_000,
                pixelSize: CGSize(width: 1200, height: 900), captureDate: nil,
                badges: [.transparent], isAvailable: true, inventory: MetadataInventory()),
            LibraryItem(
                id: UUID(), mediaKind: .video, url: URL(filePath: "/tmp/c.mov"), byteSize: 50_000_000,
                duration: 20, pixelSize: CGSize(width: 3840, height: 2160), frameRate: 60, captureDate: nil,
                badges: [.k4, .sdr], isAvailable: true, inventory: MetadataInventory()),
        ])

        let browser = LibraryBrowser(collection: collection)
        #expect(browser.snapshot.items.count == 3)

        browser.mediaFilter = .images
        #expect(browser.snapshot.items.count == 2)
        #expect(browser.snapshot.facets.megapixels.map(\.value) == [.mp48Plus, .under12])
        #expect(browser.snapshot.facets.qualities.isEmpty)

        browser.quality = QualityFilter(megapixels: [.mp48Plus], imageTraits: [.livePhoto])
        #expect(browser.snapshot.items.map(\.name) == ["a.heic"])

        browser.mediaFilter = .videos
        browser.quality = QualityFilter()
        #expect(browser.snapshot.items.map(\.name) == ["c.mov"])
        #expect(browser.snapshot.facets.qualities.map(\.value) == [.uhd(.fps60)])
        #expect(browser.snapshot.facets.megapixels.isEmpty)
    }
}

@MainActor
private final class StaticCollection: MediaCollection {
    let items: [LibraryItem]
    let revision = 1
    let isScanning = false
    init(items: [LibraryItem]) { self.items = items }
}
