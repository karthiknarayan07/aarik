import AVFoundation
import AppCore
import AppServices
import CoreGraphics
import Foundation
import LocalLibrary
import MediaEngine
import MediaTestSupport
import PhotosLibrary
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Convert
@testable import QuickRunService

@Suite(.serialized) struct ImageConvertTests {
    @Test func plannerAppliesTenPercentRuleForSameFormatAndPermitsExplicitFormatChange() throws {
        let inventory = MetadataInventory(items: [
            MetadataItem(key: "img.dimensions", category: .image, displayName: "Dimensions", value: "2400x1800"),
            MetadataItem(key: "img.uti", category: .image, displayName: "Format", value: UTType.heic.identifier),
        ])

        // Keep original format with small compression delta on tiny byte budget: keep as is (<10% rule).
        let highQuality = ImageSpec(resize: .keepOriginal, format: .keepOriginal, quality: 0.99)
        let smallDecision = ImagePlanner.decide(
            byteSize: 100_000,
            pixelSize: CGSize(width: 2400, height: 1800),
            sourceUTI: UTType.heic.identifier,
            inventory: inventory,
            spec: highQuality
        )
        guard case .keptAsIs(_, .savesLittle) = smallDecision else {
            Issue.record("Expected savesLittle when keeping same format at near-100% quality")
            return
        }

        // Explicit format change HEIC -> JPEG must convert even if file would not shrink by 10%.
        let toJPEG = ImageSpec(resize: .keepOriginal, format: .jpeg, quality: 0.95)
        let formatDecision = ImagePlanner.decide(
            byteSize: 100_000,
            pixelSize: CGSize(width: 2400, height: 1800),
            sourceUTI: UTType.heic.identifier,
            inventory: inventory,
            spec: toJPEG
        )
        guard case .convert(_, .jpeg, let outSize, _, _) = formatDecision else {
            Issue.record("Expected conversion when explicitly changing format to JPEG")
            return
        }
        #expect(outSize == CGSize(width: 2400, height: 1800))
    }

    @Test func resolutionEstimatesNeverUpscaleAndComputeLiveSizes() {
        let spec = ImageSpec(resize: .keepOriginal, format: .heic, quality: 0.80)
        let estimates = ImageLossCheck.resolutionEstimates(
            sourcePixelSize: CGSize(width: 4032, height: 3024),
            sourceBytes: 3_500_000,
            sourceUTI: UTType.heic.identifier,
            baseSpec: spec
        )
        let mp24 = estimates.first { $0.option == .mp24 }
        let mp5 = estimates.first { $0.option == .mp5 }
        let pct50 = estimates.first { $0.option == .pct50 }
        #expect(mp24?.outputPixelSize == CGSize(width: 4032, height: 3024))
        #expect(mp5 != nil && mp5!.outputMegapixels <= 5.1)
        #expect(pct50?.outputPixelSize == CGSize(width: 2016, height: 1512))
    }

    @Test func photosLossCheckReportsSpecificImageLosses() {
        let liveFlatten = ImageLossCheck.photosLostNames(
            isRAW: true, hasDepth: true, hasHDR: true, isLivePhoto: true,
            sourceUTI: UTType.rawImage.identifier,
            spec: ImageSpec(resize: .megapixels(12), format: .heic, quality: 0.80, livePhotoMode: .flattenToStill)
        )
        #expect(liveFlatten.contains("RAW sensor data"))
        #expect(liveFlatten.contains("Live Photo motion"))
        #expect(!liveFlatten.contains("HDR Gain Map"))

        let livePreservedPNG = ImageLossCheck.photosLostNames(
            isRAW: false, hasDepth: true, hasHDR: true, isLivePhoto: true,
            sourceUTI: UTType.heic.identifier,
            spec: ImageSpec(resize: .keepOriginal, format: .png, quality: 0.80, livePhotoMode: .preserve)
        )
        #expect(livePreservedPNG.contains("Portrait depth data"))
        #expect(livePreservedPNG.contains("HDR Gain Map"))
        #expect(livePreservedPNG.contains("Live Photo motion"))
    }

    @Test func localImageConvertPreservesMetadataAndSupportsSafeTrashReplace() async throws {
        var options = ImageFixtureOptions()
        options.width = 2400
        options.height = 1800
        options.utType = .png
        options.cameraMake = "Apple"
        options.cameraModel = "iPhone 17 Pro"
        options.gpsLatitude = 37.3349
        options.gpsLongitude = -122.0090
        let sourceURL = try ImageFixtureFactory.makeImage(options)
        let dir = sourceURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let trashDir = dir.appending(path: "Trash", directoryHint: .isDirectory)
        let backupDir = dir.appending(path: "OriginalsBackup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let trashed = Mutex<[URL]>([])
        let core = ConvertRunner(
            trash: { url in
                let dst = trashDir.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dst)
                trashed.withLock { $0.append(dst) }
                return dst
            },
            originalsBackup: { OriginalsBackup(folder: backupDir) },
            diskSpace: RunnerFixture.roomy
        )
        let runner = ImageConvertRunner(core: core)

        let settings = ConvertJobSettings(
            preset: .balanced,
            saveTo: .replace,
            imageSpec: ImageSpec(resize: .megapixels(2), format: .heic, quality: 0.80)
        )
        let bookmark = try sourceURL.bookmarkData()
        let job = Job(
            toolID: ConvertTool.imageToolID,
            source: sourceURL,
            sourceBookmark: bookmark,
            settings: try JSONEncoder().encode(settings)
        )

        let state = try await runner.run(job) { _ in }
        guard case .completed(let outcome) = state else {
            Issue.record("Expected completed outcome, got \(state)")
            return
        }
        #expect(outcome.replacedOriginal)
        #expect(outcome.bytesAfter < outcome.bytesBefore)
        #expect(!trashed.withLock { $0.isEmpty })

        // Verify metadata and dimensions in converted output.
        let outInspection = try ImageInspector().inspect(url: outcome.output)
        let outInventory = try ImageInspector().inventory(of: outcome.output)
        #expect(outInspection.pixelSize.width <= 1650)
        #expect(outInventory["img.tiff.make"]?.value == "Apple")
        #expect(outInventory["img.tiff.model"]?.value == "iPhone 17 Pro")
        #expect(outInventory["img.gps.location"] != nil)

        // Verify OriginalsBackup saved the source copy.
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
        #expect(!backups.isEmpty)
    }

    @Test func photosImageAndLivePhotoRoundTripWithFakePhotoStore() async throws {
        let contentID = "12345678-1234-1234-1234-1234567890AB"
        var imageOptions = ImageFixtureOptions()
        imageOptions.width = 2400
        imageOptions.height = 1800
        imageOptions.utType = .heic
        imageOptions.livePhotoContentID = contentID
        let stillURL = try ImageFixtureFactory.makeImage(imageOptions)
        let dir = stillURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        var clipOptions = ClipOptions()
        clipOptions.width = 960
        clipOptions.height = 720
        clipOptions.fps = 15
        clipOptions.videoBitRate = 8_000_000
        clipOptions.quickTimeMetadata = ["com.apple.quicktime.content.identifier": contentID]
        let pairedMov = try await FixtureFactory.makeClip(clipOptions)
        defer { try? FileManager.default.removeItem(at: pairedMov.deletingLastPathComponent()) }

        let assetID = "LIVE-PHOTO-ASSET/L0/001"
        let asset = PhotoAsset(
            id: assetID,
            mediaKind: .image,
            creationDate: Date(timeIntervalSince1970: 1_750_000_000),
            location: PhotoLocation(latitude: 48.85, longitude: 2.35),
            pixelSize: CGSize(width: 2400, height: 1800),
            isFavorite: true,
            subtypes: [.livePhoto],
            originalFileName: "IMG_LIVE.HEIC",
            originalByteSize: RunnerFixture.size(stillURL),
            pairedVideoByteSize: RunnerFixture.size(pairedMov),
            caption: "Paris Live"
        )
        let store = FakePhotoStore(assets: [asset])
        store.originalFiles[assetID] = stillURL
        store.currentVersionFiles[assetID] = stillURL
        store.pairedVideoFiles[assetID] = pairedMov
        store.existingAlbums = ["Paris"]
        store.albums[assetID] = ["Paris"]
        store.savedPixelSize = CGSize(width: 1200, height: 900)

        let workFolder = WorkFolder(root: dir.appending(path: "Work", directoryHint: .isDirectory))
        let pending = PendingDeletions(directory: dir)
        let photosRunner = PhotosConvertRunner(
            store: store,
            workFolder: workFolder,
            pendingDeletions: pending,
            core: RunnerFixture.runner()
        )

        let spec = ImageSpec(resize: .scalePercent(50), format: .heic, quality: 0.75, livePhotoMode: .preserve)
        let settings = ConvertJobSettings(
            preset: .balanced,
            saveTo: .nextToOriginal,
            imageSpec: spec,
            photosDestination: .newAsset,
            photosFileName: "IMG_LIVE.HEIC"
        )
        let job = Job(
            toolID: ConvertTool.imagePhotosToolID,
            source: PhotoAssetURL.url(for: assetID),
            sourceBookmark: Data(),
            settings: try JSONEncoder().encode(settings)
        )

        let state = try await photosRunner.run(job) { _ in }
        guard case .completed = state else {
            Issue.record("Expected completed Photos Live Photo job, got \(state)")
            return
        }
        #expect(store.saves.count == 1)
        let saved = try #require(store.saves.first)
        #expect(saved.request.mediaKind == .image)
        #expect(saved.request.pairedVideoFile != nil)
        #expect(saved.addedAlbums == ["Paris"])
        #expect(saved.request.isFavorite)
    }

    @Test func overviewSummaryAndQuickRunSupportImagesAndVideos() async throws {
        var pngOpts = ImageFixtureOptions()
        pngOpts.width = 2400
        pngOpts.height = 1800
        pngOpts.utType = .png
        let imgURL = try ImageFixtureFactory.makeImage(pngOpts)
        defer { try? FileManager.default.removeItem(at: imgURL.deletingLastPathComponent()) }

        let imgItem = LibraryItem(
            id: UUID(),
            mediaKind: .image,
            url: imgURL,
            byteSize: RunnerFixture.size(imgURL) ?? 500_000,
            pixelSize: CGSize(width: 2400, height: 1800),
            captureDate: Date(timeIntervalSince1970: 1_750_000_000),
            badges: [],
            isAvailable: true,
            inventory: try ImageInspector().inventory(of: imgURL)
        )
        let summary = OverviewSummary(
            photos: [],
            files: [imgItem],
            preset: .balanced,
            imageSpec: ImageSpec(resize: .megapixels(2), format: .heic, quality: 0.80)
        )
        #expect(summary.localFiles.count == 1)
        #expect(summary.localFiles.couldFree > 0)

        let inspected = await MediaQuickRunInspector().inspect(imgURL)
        #expect(inspected?.isImage == true)
        #expect(inspected?.inventory["img.dimensions"] != nil)
    }
}
