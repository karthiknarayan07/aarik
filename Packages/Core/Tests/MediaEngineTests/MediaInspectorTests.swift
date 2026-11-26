import AppCore
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
                $0.extendedAttributes = ["com.example.fixture": Data("x".utf8)]
            })
        let inventory = try await MediaInspector().inventory(of: url)
        #if os(macOS)
            #expect(inventory["fs.tags"]?.value == "Blue,Red")
        #endif
        let xattr = try #require(inventory["fs.xattr.com.example.fixture"])
        // SHA-256 of "x"
        #expect(xattr.value == "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
        #expect(inventory["fs.creationDate"] != nil)
    }

    @Test func inventoriesTimedMetadataTrack() async throws {
        let url = try await FixtureFactory.makeClip(smallClip { $0.includeTimedMetadataTrack = true })
        let inventory = try await MediaInspector().inventory(of: url)
        let timed = try #require(inventory["timed.mdta/com.example.fixture.timed"])
        #expect(timed.value == "present")
        #expect(timed.category == .timedMetadata)
    }

    @Test func inventoriesTrackDurationsAndAudioState() async throws {
        let url = try await FixtureFactory.makeClip(smallClip { $0.includeTimedMetadataTrack = true })
        let inventory = try await MediaInspector().inventory(of: url)
        #expect(inventory["video.duration"]?.value == "1000")
        #expect(inventory["audio.0.duration"]?.value == "1000")
        #expect(inventory["timed.mdta/com.example.fixture.timed.duration"]?.value == "1000")
        #expect(inventory["audio.0.enabled"]?.value == "true")
        #expect(inventory["audio.0.alternateGroup"]?.value == "none")
        #expect(inventory["audio.0.fallback"]?.value == "none")
    }

    // MARK: - Format description items (constructed descriptions)

    private func hevcDescription(extensions: [CFString: Any] = [:]) throws -> CMFormatDescription {
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 1920, height: 1080,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        #expect(status == noErr)
        return try #require(description)
    }

    private func atoms(_ atoms: [String: Data]) -> [CFString: Any] {
        [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
    }

    private func value(_ key: String, in items: [MetadataItem]) -> String? {
        items.first { $0.key == key }?.value
    }

    @Test func bitDepthIsUnknownWhenNothingSaysIt() throws {
        let items = TrackInspector.formatItems(try hevcDescription())
        #expect(value("video.bitDepth", in: items) == "unknown")
        #expect(VideoDownscaler.encodesTenBit(bitDepth: "unknown"))
        #expect(VideoDownscaler.encodesTenBit(bitDepth: "10"))
        #expect(!VideoDownscaler.encodesTenBit(bitDepth: "8"))
    }

    @Test func eightBitH264ProfilesReadAsEightBit() throws {
        // avcC: version 1, profile 100 (High), compat 0, level 40, lengthSize, 0 SPS, 0 PPS.
        let avcC = Data([1, 100, 0, 40, 0xFF, 0xE0, 0])
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_H264, width: 1920, height: 1080,
            extensions: atoms(["avcC": avcC]) as CFDictionary, formatDescriptionOut: &description)
        let items = TrackInspector.formatItems(try #require(description))
        #expect(value("video.bitDepth", in: items) == "8")
    }

    @Test(arguments: ["lhvC", "vexu"]) func multiviewAtomMarksStereo(atom: String) throws {
        let items = TrackInspector.formatItems(try hevcDescription(extensions: atoms([atom: Data([1, 2, 3])])))
        #expect(value("hdr.stereo", in: items) == "multiview (\(atom))")
    }

    @Test func staticHDRMetadataIsInventoriedAsHex() throws {
        let mastering = Data((0..<24).map { UInt8($0) })
        let lightLevel = Data([0x03, 0xE8, 0x01, 0x90])
        let ambient = Data([0, 0, 0x13, 0x88, 0x3D, 0x13, 0x40, 0x42])
        let items = TrackInspector.formatItems(
            try hevcDescription(extensions: [
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume: mastering,
                kCMFormatDescriptionExtension_ContentLightLevelInfo: lightLevel,
                kCMFormatDescriptionExtension_AmbientViewingEnvironment: ambient,
            ]))
        #expect(value("hdr.masteringDisplay", in: items) == "000102030405060708090a0b0c0d0e0f1011121314151617")
        #expect(value("hdr.contentLightLevel", in: items) == "03e80190")
        #expect(value("hdr.ambientViewingEnvironment", in: items) == "000013883d134042")
    }

    @Test func fileAttributesCopy() async throws {
        let source = try await FixtureFactory.makeClip(
            smallClip {
                $0.finderTags = ["Green"]
                $0.extendedAttributes = ["com.example.fixture.copy": Data("payload".utf8)]
            })
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: source.path)

        let destination = source.deletingLastPathComponent().appending(path: "copy.mov")
        try Data("dest".utf8).write(to: destination)
        try FileAttributes.copy(from: source, to: destination)

        let values = try destination.resourceValues(forKeys: [.creationDateKey])
        #if os(macOS)
            #expect(try destination.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Green"])
        #endif
        #expect(values.creationDate == created)
        let sourceItems = try FileAttributes.read(source)
        let destinationItems = try FileAttributes.read(destination)
        let sourceXattr = try #require(sourceItems.first { $0.key == "fs.xattr.com.example.fixture.copy" })
        #expect(destinationItems.first { $0.key == "fs.xattr.com.example.fixture.copy" }?.value == sourceXattr.value)
        #if os(macOS)
            #expect(destinationItems.first { $0.key == "fs.tags" }?.value == "Green")
        #endif
    }

    @Test func fileAttributesCopySkipsExcludedSystemAttributes() async throws {
        // A real `com.apple.macl` can be written by an unsandboxed test process; `com.apple.rootless` cannot.
        let source = try await FixtureFactory.makeClip(
            smallClip {
                $0.finderTags = ["Green"]
                $0.extendedAttributes = [
                    "com.apple.macl": Data("acl".utf8), "com.example.fixture.keep": Data("k".utf8),
                ]
            })
        #expect(getxattr(source.path, "com.apple.macl", nil, 0, 0, 0) == 3)
        for name in ["com.apple.macl", "com.apple.rootless"] {
            #expect(FileAttributes.excludedAttributes.contains(name))
        }

        let sourceItems = try FileAttributes.read(source)
        #expect(!sourceItems.contains { $0.key == "fs.xattr.com.apple.macl" })
        #expect(sourceItems.contains { $0.key == "fs.xattr.com.example.fixture.keep" })

        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: source.path)
        let destination = source.deletingLastPathComponent().appending(path: "copy.mov")
        try Data("dest".utf8).write(to: destination)
        try FileAttributes.copy(from: source, to: destination)

        #expect(getxattr(destination.path, "com.apple.macl", nil, 0, 0, 0) == -1)
        let values = try destination.resourceValues(forKeys: [.creationDateKey])
        #if os(macOS)
            #expect(try destination.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Green"])
        #endif
        #expect(values.creationDate == created)
        #expect(try FileAttributes.read(destination).contains { $0.key == "fs.xattr.com.example.fixture.keep" })
    }
}
