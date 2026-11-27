import AppCore
import CoreGraphics
import Foundation
import MediaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import MediaEngine

@Suite struct ImageConverterTests {
    @Test func convertsRotatedHEICAndPreservesMetadataGainMapAndXattrs() async throws {
        var options = ImageFixtureOptions()
        options.width = 1600
        options.height = 1200
        options.orientation = 6
        options.utType = .heic
        options.livePhotoContentID = "PAIR-UUID-999"
        options.includeGainMap = true
        options.extendedAttributes = ["com.example.tag": Data("v1".utf8)]
        let source = try ImageFixtureFactory.makeImage(options)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let dest = source.deletingLastPathComponent().appending(path: "converted.heic")
        let spec = ImageSpec(resize: .scalePercent(50), format: .heic, quality: 0.78)
        let result = try await ImageConverter().convert(source: source, to: dest, spec: spec)

        #expect(result.pixelSize == CGSize(width: 600, height: 800))

        let inspector = ImageInspector()
        let outInfo = try inspector.inspect(url: dest)
        #expect(outInfo.pixelSize == CGSize(width: 600, height: 800))
        #expect(outInfo.orientation == 1)
        #expect(outInfo.hasHDRGainMap)

        let diff = MetadataDiff.report(
            source: try inspector.inventory(of: source), output: try inspector.inventory(of: dest))
        #expect(diff.lost.isEmpty, "Unexpected metadata lost: \(diff.lost.map(\.key))")
        let unexpected = ExpectedChanges.unexpected(in: diff, spec: spec)
        #expect(unexpected.isEmpty, "Unexpected metadata changed: \(unexpected.map(\.key))")

        // No partial files remain
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        #expect(!dirContents.contains { $0.contains(".partial-") })
    }

    @Test func preservesAlphaInPNGAndSupportsAVIFAndGIFAnimation() async throws {
        var pngOpts = ImageFixtureOptions()
        pngOpts.width = 400
        pngOpts.height = 400
        pngOpts.utType = .png
        pngOpts.withAlpha = true
        let pngURL = try ImageFixtureFactory.makeImage(pngOpts)
        defer { try? FileManager.default.removeItem(at: pngURL.deletingLastPathComponent()) }

        let pngOut = pngURL.deletingLastPathComponent().appending(path: "scaled.png")
        let pngResult = try await ImageConverter().convert(
            source: pngURL, to: pngOut, spec: ImageSpec(resize: .scalePercent(50), format: .png))
        #expect(pngResult.pixelSize == CGSize(width: 200, height: 200))
        #expect(try ImageInspector().inspect(url: pngOut).hasAlpha)

        if ImageOutputFormat.avif.isEncodingSupported {
            let avifOut = pngURL.deletingLastPathComponent().appending(path: "scaled.avif")
            let avifResult = try await ImageConverter().convert(
                source: pngURL, to: avifOut, spec: ImageSpec(resize: .scalePercent(50), format: .avif, quality: 0.7))
            #expect(avifResult.pixelSize == CGSize(width: 200, height: 200))
        }

        var gifOpts = ImageFixtureOptions()
        gifOpts.width = 160
        gifOpts.height = 120
        gifOpts.utType = .gif
        gifOpts.frameCount = 4
        let gifURL = try ImageFixtureFactory.makeImage(gifOpts)
        defer { try? FileManager.default.removeItem(at: gifURL.deletingLastPathComponent()) }

        let gifOut = gifURL.deletingLastPathComponent().appending(path: "small.gif")
        _ = try await ImageConverter().convert(
            source: gifURL, to: gifOut, spec: ImageSpec(resize: .scalePercent(50), format: .gif))
        let outGifInfo = try ImageInspector().inspect(url: gifOut)
        #expect(outGifInfo.frameCount == 4)
        #expect(outGifInfo.pixelSize == CGSize(width: 80, height: 60))
    }

    @Test func targetByteSizeConvergesOrFailsCleanlyWhenImpossible() async throws {
        var options = ImageFixtureOptions()
        options.width = 1200
        options.height = 900
        options.utType = .jpeg
        let source = try ImageFixtureFactory.makeImage(options)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let dest = source.deletingLastPathComponent().appending(path: "capped.jpg")
        let target: Int64 = 45_000
        let result = try await ImageConverter().convert(
            source: source, to: dest,
            spec: ImageSpec(resize: .keepOriginal, format: .jpeg, quality: 0.90, targetByteSize: target))
        #expect(result.byteSize <= target)

        let impossibleDest = source.deletingLastPathComponent().appending(path: "impossible.jpg")
        await #expect(throws: ImageConversionError.self) {
            _ = try await ImageConverter().convert(
                source: source, to: impossibleDest,
                spec: ImageSpec(resize: .keepOriginal, format: .jpeg, quality: 0.90, targetByteSize: 500))
        }
    }

    @Test func refusesToOverwriteExistingDestination() async throws {
        let source = try ImageFixtureFactory.makeImage()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let dest = source.deletingLastPathComponent().appending(path: "existing.heic")
        try Data("keep".utf8).write(to: dest)

        await #expect(throws: ImageConversionError.outputExists) {
            _ = try await ImageConverter().convert(source: source, to: dest, spec: ImageSpec())
        }
        #expect(try Data(contentsOf: dest) == Data("keep".utf8))
    }
}
