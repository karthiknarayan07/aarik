import AppCore
import Testing

@testable import MediaEngine

@Suite struct ExpectedChangesTests {
    private func change(_ key: String, _ from: String, _ to: String) -> MetadataChange {
        MetadataChange(key: key, displayName: key, from: from, to: to)
    }

    private func unexpected(_ changes: [MetadataChange], spec: DownscaleSpec = DownscaleSpec()) -> [String] {
        ExpectedChanges.unexpected(in: MetadataReport(changed: changes), spec: spec).map(\.key)
    }

    @Test func dimensionsCodecAndDolbyVisionLevelAreExpected() {
        let changes = [
            change("video.dimensions", "3840x2160", "1920x1080"),
            change("video.codec", "avc1", "hvc1"),
            change("hdr.dolbyVision", "profile 8, level 9, compat 4", "profile 8, level 6, compat 4"),
        ]
        #expect(unexpected(changes).isEmpty)
    }

    @Test func otherChangesAreUnexpected() {
        let changes = [
            change("video.duration", "1000", "990"),
            change("video.bitDepth", "10", "8"),
            change("hdr.dolbyVision", "profile 8, level 9, compat 4", "profile 5, level 9, compat 0"),
            change("hdr.dolbyVision", "present", "profile 8, level 9, compat 4"),
        ]
        #expect(unexpected(changes) == ["video.duration", "video.bitDepth", "hdr.dolbyVision", "hdr.dolbyVision"])
    }

    @Test func frameRateIsExpectedOnlyWithACap() {
        let changes = [change("video.frameRate", "60.00", "30.00")]
        #expect(unexpected(changes) == ["video.frameRate"])
        #expect(unexpected(changes, spec: DownscaleSpec(maxFrameRate: 30)).isEmpty)
    }
}
