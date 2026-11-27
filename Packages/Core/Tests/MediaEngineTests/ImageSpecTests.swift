import CoreGraphics
import Foundation
import Testing

@testable import MediaEngine

@Suite struct ImageSpecTests {
    @Test func megapixelResizeDownscalesAndPreservesAspectWithoutUpscaling() {
        // 48 MP photo (8064 x 6048) -> 24 MP -> ~5702 x 4277
        let source48MP = CGSize(width: 8064, height: 6048)
        let target24MP = ImageResizeMode.megapixels(24).outputSize(for: source48MP)
        #expect(target24MP.width < source48MP.width)
        #expect(target24MP.height < source48MP.height)
        let mp = (target24MP.width * target24MP.height) / 1_000_000.0
        #expect(abs(mp - 24.0) < 0.2)
        #expect(abs((target24MP.width / target24MP.height) - (4.0 / 3.0)) < 0.01)

        // Small 12 MP photo (4000 x 3000) requested at 24 MP -> never upscales
        let source12MP = CGSize(width: 4000, height: 3000)
        #expect(ImageResizeMode.megapixels(24).outputSize(for: source12MP) == source12MP)
    }

    @Test func scalePercentAndCustomBoundsNeverUpscale() {
        let landscape = CGSize(width: 4000, height: 2000)
        #expect(ImageResizeMode.scalePercent(50).outputSize(for: landscape) == CGSize(width: 2000, height: 1000))
        #expect(ImageResizeMode.scalePercent(150).outputSize(for: landscape) == landscape)

        // Custom bounds 1000x1000 fits long edge cleanly
        #expect(
            ImageResizeMode.customBounds(width: 1000, height: 1000).outputSize(for: landscape)
                == CGSize(width: 1000, height: 500))
        // Custom bounds larger than source never upscale
        #expect(ImageResizeMode.customBounds(width: 6000, height: 6000).outputSize(for: landscape) == landscape)
    }

    @Test func keepOriginalFormatMapsReadOnlyContainersToHEIC() {
        #expect(ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: "public.jpeg") == .jpeg)
        #expect(ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: "public.png") == .png)
        #expect(ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: "public.heic") == .heic)
        #expect(ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: "org.webmproject.webp") == .heic)
        #expect(ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: "com.adobe.raw-image") == .heic)
        #expect(ImageOutputFormat.keepOriginal.resolvedFormat(sourceUTI: "public.avif") == .avif)
    }
}
