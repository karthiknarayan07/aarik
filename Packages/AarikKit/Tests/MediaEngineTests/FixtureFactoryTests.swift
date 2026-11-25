import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import MediaTestSupport

@Suite struct FixtureFactoryTests {
    @Test func makesHLGClipWithRequestedShape() async throws {
        let url = try await FixtureFactory.makeClip()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 3840, height: 2160))
        let descriptions = try await track.load(.formatDescriptions)
        let desc = try #require(descriptions.first)
        let transfer =
            CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        #expect(transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.0) <= 0.05)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func writesQuickTimeMetadata() async throws {
        var options = ClipOptions()
        options.width = 640
        options.height = 360
        options.quickTimeMetadata = [
            "com.apple.quicktime.make": "Apple",
            "com.apple.quicktime.location.ISO6709": "+12.9716+077.5946+000.000/",
        ]
        let url = try await FixtureFactory.makeClip(options)
        let items = try await AVURLAsset(url: url).load(.metadata)
        for (key, expected) in options.quickTimeMetadata {
            let item = try #require(items.first { ($0.key as? String) == key })
            #expect(try await item.load(.stringValue) == expected)
        }
    }

    @Test func appliesRotationTagsAndXattrs() async throws {
        var options = ClipOptions()
        options.width = 640
        options.height = 360
        options.rotationDegrees = 90
        options.finderTags = ["Red"]
        options.extendedAttributes = ["com.aarik.test": Data("x".utf8)]
        options.includeTimedMetadataTrack = true
        let url = try await FixtureFactory.makeClip(options)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let t = try await track.load(.preferredTransform)
        #expect(abs(t.a) < 0.001 && abs(t.d) < 0.001 && abs(t.b - 1) < 0.001 && abs(t.c + 1) < 0.001)
        #expect(try await asset.loadTracks(withMediaType: .metadata).count == 1)

        let tags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(tags == ["Red"])
        let size = getxattr(url.path, "com.aarik.test", nil, 0, 0, 0)
        #expect(size == 1)
        var buf = [UInt8](repeating: 0, count: 1)
        #expect(getxattr(url.path, "com.aarik.test", &buf, 1, 0, 0) == 1)
        #expect(buf == Array("x".utf8))
    }
}
