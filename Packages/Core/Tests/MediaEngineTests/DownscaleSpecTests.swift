import Foundation
import CoreGraphics
import MediaEngine
import Testing

@Suite struct DownscaleSpecTests {
    @Test func landscape4KTo1080() {
        #expect(
            DownscaleSpec().outputSize(forNaturalSize: CGSize(width: 3840, height: 2160))
                == CGSize(width: 1920, height: 1080))
    }

    @Test func oddAspectRoundsToEven() {
        #expect(
            DownscaleSpec().outputSize(forNaturalSize: CGSize(width: 4096, height: 2160))
                == CGSize(width: 2048, height: 1080))
    }

    @Test func portraitStoredUprightUsesShortSide() {
        #expect(
            DownscaleSpec().outputSize(forNaturalSize: CGSize(width: 2160, height: 3840))
                == CGSize(width: 1080, height: 1920))
    }
}

@Suite struct DownscaleSpecCodingTests {
    @Test func roundTripsThroughJSON() throws {
        for spec in [
            DownscaleSpec(), DownscaleSpec(targetShortSide: nil, averageBitRate: 5, maxFrameRate: 30),
            DownscaleSpec(targetShortSide: 720, averageBitRate: 8, codec: .h264Compatible),
        ] {
            let data = try JSONEncoder().encode(spec)
            #expect(try JSONDecoder().decode(DownscaleSpec.self, from: data) == spec)
        }
    }

    @Test func olderJSONWithoutACodecDecodesAsHEVC() throws {
        let json = Data(#"{"targetShortSide":1080,"averageBitRate":9000000}"#.utf8)
        let spec = try JSONDecoder().decode(DownscaleSpec.self, from: json)
        #expect(spec == DownscaleSpec(targetShortSide: 1080, averageBitRate: 9_000_000))
        #expect(spec.codec == .hevcKeepHDR)
    }

    @Test func keepingResolutionOnlyEvensTheSize() {
        let spec = DownscaleSpec(targetShortSide: nil)
        #expect(spec.outputSize(forNaturalSize: CGSize(width: 1281, height: 720)) == CGSize(width: 1282, height: 720))
    }
}
