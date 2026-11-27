import AppCore
import CoreGraphics
import Foundation
import MediaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import MediaEngine

@Suite struct ImageInspectorTests {
    @Test func readsUprightDimensionsForRotatedEXIFAndCapturesAllMetadata() async throws {
        var options = ImageFixtureOptions()
        options.width = 800
        options.height = 600
        options.orientation = 6  // Rotated 90 deg CW: raw 800x600 displays as 600x800
        options.utType = .heic
        options.livePhotoContentID = "12345678-1234-1234-1234-1234567890AB"
        options.includeGainMap = true
        options.extendedAttributes = ["com.example.note": Data("hello".utf8)]
        let url = try ImageFixtureFactory.makeImage(options)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let inspector = ImageInspector()
        let inspection = try inspector.inspect(url: url)
        #expect(inspection.pixelSize == CGSize(width: 600, height: 800))
        #expect(inspection.orientation == 6)
        #expect(inspection.hasHDRGainMap)
        #expect(!inspection.isAnimated)

        let inventory = try inspector.inventory(of: url)
        #expect(inventory["img.tiff.make"]?.value == "Apple")
        #expect(inventory["img.tiff.model"]?.value == "iPhone 17 Pro")
        #expect(inventory["img.exif.lensModel"]?.value == "Main 24mm f/1.78")
        #expect(inventory["img.gps.location"]?.value == "37.3349,-122.0090")
        #expect(inventory["img.iptc.caption"]?.value == "Test photo caption")
        #expect(inventory["img.apple.contentID"]?.value == "12345678-1234-1234-1234-1234567890AB")
        #expect(inventory["img.hdrGainMap"]?.value == "present")
        #expect(inventory["fs.xattr.com.example.note"] != nil)
    }

    @Test func detectsAlphaAndAnimatedFrames() async throws {
        var pngOpts = ImageFixtureOptions()
        pngOpts.width = 200
        pngOpts.height = 200
        pngOpts.utType = .png
        pngOpts.withAlpha = true
        let pngURL = try ImageFixtureFactory.makeImage(pngOpts)
        defer { try? FileManager.default.removeItem(at: pngURL.deletingLastPathComponent()) }

        let pngInfo = try ImageInspector().inspect(url: pngURL)
        #expect(pngInfo.hasAlpha)
        #expect(!pngInfo.isAnimated)

        var gifOpts = ImageFixtureOptions()
        gifOpts.width = 120
        gifOpts.height = 120
        gifOpts.utType = .gif
        gifOpts.frameCount = 3
        let gifURL = try ImageFixtureFactory.makeImage(gifOpts)
        defer { try? FileManager.default.removeItem(at: gifURL.deletingLastPathComponent()) }

        let gifInfo = try ImageInspector().inspect(url: gifURL)
        #expect(gifInfo.isAnimated)
        #expect(gifInfo.frameCount == 3)
    }
}
