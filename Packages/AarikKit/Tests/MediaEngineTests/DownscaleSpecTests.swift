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
