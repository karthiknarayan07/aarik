import CoreMedia
import Foundation
import MediaTestSupport
import Testing

@testable import MediaEngine

@Suite struct MediaInspectorTests {
    private func smallClip(_ configure: (inout ClipOptions) -> Void = { _ in }) -> ClipOptions {
        var options = ClipOptions()
        options.width = 640
        options.height = 360
        configure(&options)
        return options
    }

    @Test func inventoriesHLGClip() async throws {
        let url = try await FixtureFactory.makeClip()
        let inventory = try await MediaInspector().inventory(of: url)
        #expect(inventory["video.dimensions"]?.value == "3840x2160")
        #expect(
            inventory["video.transferFunction"]?.value
                == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String))
        #expect(inventory["video.bitDepth"]?.value == "10")
        #expect(inventory["audio.0.channels"]?.value == "2")
        // The brief expected no `hdr.dolbyVision` here, but VideoToolbox's HEVC Main10 HLG encoder writes a
        // `dvvC` atom (Dolby Vision profile 8.4) on its own. The no-false-positive check lives on the SDR fixture.
        let dolbyVision = try #require(inventory["hdr.dolbyVision"])
        #expect(dolbyVision.value.hasPrefix("profile 8, level ") && dolbyVision.value.hasSuffix(", compat 4"))
    }

    @Test func inventoriesAllQuickTimeKeysIncludingUnknown() async throws {
        let url = try await FixtureFactory.makeClip(
            smallClip {
                $0.quickTimeMetadata = [
                    "com.apple.quicktime.make": "Apple",
                    "com.apple.quicktime.some-future-key": "future value",
                ]
            })
        let inventory = try await MediaInspector().inventory(of: url)
        let make = try #require(inventory["qt.com.apple.quicktime.make"])
        #expect(make.value == "Apple")
        #expect(make.category == .camera)
        #expect(make.displayName == "Camera make")
        let future = try #require(inventory["qt.com.apple.quicktime.some-future-key"])
        #expect(future.value == "future value")
        #expect(future.displayName == "some-future-key")
    }

    @Test func inventoriesFileSystemAttributes() async throws {
        let url = try await FixtureFactory.makeClip(
            smallClip {
                $0.finderTags = ["Red", "Blue"]
                $0.extendedAttributes = ["com.aarik.test": Data("x".utf8)]
            })
        let inventory = try await MediaInspector().inventory(of: url)
        #expect(inventory["fs.tags"]?.value == "Blue,Red")
        let xattr = try #require(inventory["fs.xattr.com.aarik.test"])
        // SHA-256 of "x"
        #expect(xattr.value == "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
        #expect(inventory["fs.creationDate"] != nil)
    }

    @Test func inventoriesTimedMetadataTrack() async throws {
        let url = try await FixtureFactory.makeClip(smallClip { $0.includeTimedMetadataTrack = true })
        let inventory = try await MediaInspector().inventory(of: url)
        let timed = try #require(inventory["timed.mdta/com.aarik.test.timed"])
        #expect(timed.value == "present")
        #expect(timed.category == .timedMetadata)
    }

    @Test func fileAttributesCopy() async throws {
        let source = try await FixtureFactory.makeClip(
            smallClip {
                $0.finderTags = ["Green"]
                $0.extendedAttributes = ["com.aarik.copy": Data("payload".utf8)]
            })
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: source.path)

        let destination = source.deletingLastPathComponent().appending(path: "copy.mov")
        try Data("dest".utf8).write(to: destination)
        try FileAttributes.copy(from: source, to: destination)

        let values = try destination.resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
        #expect(values.tagNames == ["Green"])
        #expect(values.creationDate == created)
        let sourceItems = try FileAttributes.read(source)
        let destinationItems = try FileAttributes.read(destination)
        let sourceXattr = try #require(sourceItems.first { $0.key == "fs.xattr.com.aarik.copy" })
        #expect(destinationItems.first { $0.key == "fs.xattr.com.aarik.copy" }?.value == sourceXattr.value)
        #expect(destinationItems.first { $0.key == "fs.tags" }?.value == "Green")
    }
}
