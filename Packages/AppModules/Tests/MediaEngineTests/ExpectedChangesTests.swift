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
            change("video.duration", "1000", "800"),
            change("video.bitDepth", "10", "8"),
            change("hdr.dolbyVision", "profile 8, level 9, compat 4", "profile 5, level 9, compat 0"),
            change("hdr.dolbyVision", "present", "profile 8, level 9, compat 4"),
        ]
        #expect(unexpected(changes) == ["video.duration", "video.bitDepth", "hdr.dolbyVision", "hdr.dolbyVision"])
    }

    @Test func durationsMayMoveByLessThanATenthOfASecond() {
        let changes = [
            change("video.duration", "2335", "2337"),
            change("audio.0.duration", "14813", "14764"),
            change("timed.mdta/com.apple.quicktime.scene-illuminance.duration", "15398", "15397"),
        ]
        #expect(unexpected(changes).isEmpty)
        #expect(unexpected([change("audio.0.duration", "14813", "14713")]) == ["audio.0.duration"])
        #expect(unexpected([change("video.duration", "1000", "unknown")]) == ["video.duration"])
    }

    @Test func frameRateIsExpectedOnlyWithACap() {
        let changes = [change("video.frameRate", "60.00", "30.00")]
        #expect(unexpected(changes) == ["video.frameRate"])
        #expect(unexpected(changes, spec: DownscaleSpec(maxFrameRate: 30)).isEmpty)
    }

    @Test func h264AcceptsTheSDRColorAndBitDepthChanges() {
        let changes = [
            change("video.codec", "hvc1", "avc1"),
            change("video.transferFunction", "ITU_R_2100_HLG", "ITU_R_709_2"),
            change("video.colorPrimaries", "ITU_R_2020", "ITU_R_709_2"),
            change("video.matrix", "ITU_R_2020", "ITU_R_709_2"),
            change("video.bitDepth", "10", "8"),
        ]
        #expect(unexpected(changes, spec: DownscaleSpec(codec: .h264Compatible)).isEmpty)
        // The same changes from an HEVC encode mean it went wrong.
        #expect(
            unexpected(changes)
                == ["video.transferFunction", "video.colorPrimaries", "video.matrix", "video.bitDepth"])
        // Anything else is still unexpected for H.264.
        #expect(
            unexpected([change("video.duration", "1000", "800")], spec: DownscaleSpec(codec: .h264Compatible))
                == ["video.duration"])
    }

    @Test func h264AcceptsOnlyChangesThatLandOnSDR() {
        let h264 = DownscaleSpec(codec: .h264Compatible)
        let wrong = [
            change("video.transferFunction", "ITU_R_709_2", "ITU_R_2100_HLG"),
            change("video.colorPrimaries", "ITU_R_709_2", "ITU_R_2020"),
            change("video.matrix", "ITU_R_709_2", "ITU_R_2020"),
            change("video.bitDepth", "8", "10"),
        ]
        #expect(
            unexpected(wrong, spec: h264)
                == ["video.transferFunction", "video.colorPrimaries", "video.matrix", "video.bitDepth"])
        #expect(
            unexpected([change("video.transferFunction", "ITU_R_2020_PQ", "ITU_R_2100_HLG")], spec: h264).count == 1)
    }
}
