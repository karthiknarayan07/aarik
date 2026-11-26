import AppCore
import CoreGraphics
import Foundation
import Testing

@testable import LocalLibrary

@Suite struct QualityFilterTests {
    private func item(
        width: Double = 1920, height: Double = 1080, fps: Double = 30, bytes: Int64 = 1_000_000,
        seconds: Double = 10, badges: Set<MediaBadge> = [.sdr], codec: String? = "hvc1", name: String = "clip.mov"
    ) -> LibraryItem {
        let inventory = MetadataInventory(
            items: codec.map { [MetadataItem(key: "video.codec", category: .video, displayName: "Codec", value: $0)] }
                ?? [])
        return LibraryItem(
            id: UUID(), url: URL(filePath: "/nonexistent/\(name)"), byteSize: bytes, duration: seconds,
            pixelSize: CGSize(width: width, height: height), frameRate: fps, captureDate: nil, badges: badges,
            isAvailable: true, inventory: inventory)
    }

    // MARK: - Buckets

    @Test(arguments: [
        (240.0, FrameRateTier.fps120Plus), (120, .fps120Plus), (100, .fps120Plus), (99.9, .fps60), (60, .fps60),
        (59.94, .fps60), (50, .fps60), (49.9, .fps30), (30, .fps30), (29.97, .fps30), (28, .fps30), (27.9, .fps25),
        (25, .fps25), (24.5, .fps25), (24.4, .fps24), (24, .fps24), (23.976, .fps24), (23, .fps24), (22.9, .under23),
        (15, .under23),
    ])
    func frameRateTiers(fps: Double, tier: FrameRateTier) {
        #expect(FrameRateTier(fps: fps) == tier)
    }

    @Test func unknownFrameRateHasNoTier() {
        #expect(FrameRateTier(fps: 0) == nil)
        #expect(FrameRateTier(fps: -1) == nil)
        #expect(FrameRateTier(fps: .nan) == nil)
    }

    @Test func resolutionUsesTheShortSide() {
        #expect(QualityBucket(item: item(width: 3840, height: 2160, fps: 60)) == .uhd(.fps60))
        // Portrait 4K is still 4K.
        #expect(QualityBucket(item: item(width: 2160, height: 3840, fps: 29.97)) == .uhd(.fps30))
        // Cinema 4K and wider-than-UHD sizes count by the short side.
        #expect(QualityBucket(item: item(width: 4096, height: 2160, fps: 24)) == .uhd(.fps24))
        #expect(QualityBucket(item: item(width: 1920, height: 1080, fps: 59.94)) == .fullHD(.fps60))
        #expect(QualityBucket(item: item(width: 1080, height: 1920, fps: 30)) == .fullHD(.fps30))
        // 2.7K (short side 1520) is 1080p-class.
        #expect(QualityBucket(item: item(width: 2704, height: 1520, fps: 30)) == .fullHD(.fps30))
        #expect(QualityBucket(item: item(width: 1280, height: 720, fps: 60)) == .hd)
        #expect(QualityBucket(item: item(width: 1919, height: 1079, fps: 30)) == .hd)
        #expect(QualityBucket(item: item(width: 640, height: 480, fps: 30)) == .other)
    }

    @Test func unknownFrameRateKeepsResolution() {
        #expect(QualityBucket(item: item(width: 3840, height: 2160, fps: 0)) == .uhd(nil))
        #expect(QualityBucket(item: item(width: 3840, height: 2160, fps: 0)).title == "4K")
        #expect(QualityBucket(item: item(width: 1920, height: 1080, fps: 0)) == .fullHD(nil))
        #expect(QualityBucket(item: item(width: 1920, height: 1080, fps: 0)).title == "1080p")
        #expect(QualityBucket(item: item(width: 0, height: 0, fps: 30)) == .unknown)
        // Frame rate isn't part of 720p and Other, so an unknown rate doesn't hide their resolution.
        #expect(QualityBucket(item: item(width: 1280, height: 720, fps: 0)) == .hd)
        #expect(QualityBucket(item: item(width: 640, height: 480, fps: 0)) == .other)
    }

    @Test func unknownCodecAndRangeAreOmittedFromFacets() {
        let unknown = item(width: 3840, height: 2160, fps: 0, badges: [], codec: nil)
        let (_, facets) = QualityFilter().apply(to: [unknown])
        #expect(facets.qualities.map(\.value) == [.uhd(nil)])
        #expect(facets.codecs.isEmpty)
        #expect(facets.ranges.isEmpty)
    }

    @Test func bucketTitlesAndOrder() {
        let buckets: [QualityBucket] = [
            .unknown, .other, .hd, .fullHD(.fps30), .fullHD(.fps60), .uhd(.fps24), .uhd(.fps30), .uhd(.fps60),
            .uhd(.fps120Plus), .uhd(.under23),
        ]
        #expect(
            buckets.sorted().map(\.title) == [
                "4K120+", "4K60", "4K30", "4K24", "4K, under 23 fps", "1080p60", "1080p30", "720p", "Other",
                "Unknown",
            ])
        #expect(QualityBucket.fullHD(.fps25).title == "1080p25")
    }

    @Test func codecFamilies() {
        #expect(CodecFamily(code: "hvc1") == .hevc)
        #expect(CodecFamily(code: "hev1") == .hevc)
        #expect(CodecFamily(code: "dvh1") == .hevc)
        #expect(CodecFamily(code: "avc1") == .h264)
        #expect(CodecFamily(code: "apcn") == .proRes)
        #expect(CodecFamily(code: "ap4h") == .proRes)
        #expect(CodecFamily(code: "apch") == .proRes)
        #expect(CodecFamily(code: "mp4v") == .other)
        #expect(CodecFamily(code: nil) == .other)
        #expect(CodecFamily(item: item(codec: "avc1")) == .h264)
        #expect(CodecFamily(item: item(codec: nil)) == .other)
    }

    @Test func dynamicRangeFromBadges() {
        // A Dolby Vision clip also carries the HDR badge; it counts once, as Dolby Vision.
        #expect(DynamicRange(badges: [.dolbyVision, .hdr, .k4]) == .dolbyVision)
        #expect(DynamicRange(badges: [.hdr]) == .hdr)
        #expect(DynamicRange(badges: [.sdr]) == .sdr)
        #expect(DynamicRange(badges: []) == .sdr)
    }

    @Test func lengthRanges() {
        #expect(LengthRange(seconds: 0) == .unknown)
        #expect(LengthRange(seconds: .nan) == .unknown)
        #expect(LengthRange(seconds: 29.9) == .underThirtySeconds)
        #expect(LengthRange(seconds: 30) == .upToTwoMinutes)
        #expect(LengthRange(seconds: 119) == .upToTwoMinutes)
        #expect(LengthRange(seconds: 120) == .upToTenMinutes)
        #expect(LengthRange(seconds: 600) == .overTenMinutes)
    }

    @Test func sizeThresholdsAreStrictAndDecimal() {
        let filter = QualityFilter(minimumSize: .over100MB)
        #expect(!filter.matches(item(bytes: 100_000_000)))
        #expect(filter.matches(item(bytes: 100_000_001)))
        #expect(QualityFilter(minimumSize: .over1GB).matches(item(bytes: 1_073_741_824)))
    }

    // MARK: - Combination

    @Test func emptyFilterMatchesEverything() {
        let filter = QualityFilter()
        #expect(!filter.isActive)
        #expect(filter.activeCount == 0)
        #expect(filter.matches(item(width: 0, height: 0, fps: 0, bytes: 0, seconds: 0, badges: [], codec: nil)))
    }

    @Test func choicesWithinADimensionAreAlternatives() {
        let filter = QualityFilter(qualities: [.uhd(.fps60), .fullHD(.fps30)])
        #expect(filter.matches(item(width: 3840, height: 2160, fps: 60)))
        #expect(filter.matches(item(width: 1920, height: 1080, fps: 30)))
        #expect(!filter.matches(item(width: 3840, height: 2160, fps: 30)))
    }

    @Test func dimensionsCombineWithAnd() {
        let filter = QualityFilter(
            qualities: [.uhd(.fps60)], minimumSize: .over500MB, lengths: [.upToTwoMinutes], codecs: [.hevc],
            ranges: [.dolbyVision])
        #expect(filter.isActive)
        #expect(filter.activeCount == 5)
        func clip(
            fps: Double = 59.94, bytes: Int64 = 800_000_000, seconds: Double = 60,
            badges: Set<MediaBadge> = [.dolbyVision, .hdr], codec: String = "hvc1"
        ) -> LibraryItem {
            item(width: 3840, height: 2160, fps: fps, bytes: bytes, seconds: seconds, badges: badges, codec: codec)
        }
        #expect(filter.matches(clip()))
        // Failing any one dimension excludes the item.
        #expect(!filter.matches(clip(fps: 30)))
        #expect(!filter.matches(clip(bytes: 400_000_000)))
        #expect(!filter.matches(clip(seconds: 10)))
        #expect(!filter.matches(clip(codec: "avc1")))
        #expect(!filter.matches(clip(badges: [.hdr])))
    }

    // MARK: - Facets

    @Test func facetsListOnlyPresentOptionsInOrder() {
        let items = [
            item(width: 3840, height: 2160, fps: 60, bytes: 2_000_000_000, badges: [.dolbyVision, .hdr]),
            item(width: 3840, height: 2160, fps: 60, bytes: 600_000_000, badges: [.dolbyVision, .hdr]),
            item(width: 1920, height: 1080, fps: 30, bytes: 50_000_000, codec: "avc1"),
        ]
        let (kept, facets) = QualityFilter().apply(to: items)
        #expect(kept.count == 3)
        #expect(facets.qualities.map(\.value) == [.uhd(.fps60), .fullHD(.fps30)])
        #expect(facets.qualities.map(\.count) == [2, 1])
        #expect(facets.sizes.map(\.value) == [.over100MB, .over500MB, .over1GB])
        #expect(facets.sizes.map(\.count) == [2, 2, 1])
        #expect(facets.qualities.map(\.bytes) == [2_600_000_000, 50_000_000])
        #expect(facets.sizes.map(\.bytes) == [2_600_000_000, 2_600_000_000, 2_000_000_000])
        #expect(facets.codecs.map(\.value) == [.hevc, .h264])
        #expect(facets.ranges.map(\.value) == [.dolbyVision, .sdr])
        #expect(facets.lengths.map(\.value) == [.underThirtySeconds])
    }

    @Test func facetCountsIgnoreTheirOwnDimension() {
        let items = [
            item(width: 3840, height: 2160, fps: 60, codec: "hvc1"),
            item(width: 3840, height: 2160, fps: 30, codec: "hvc1"),
            item(width: 1920, height: 1080, fps: 30, codec: "avc1"),
        ]
        let (kept, facets) = QualityFilter(qualities: [.uhd(.fps60)], codecs: [.hevc]).apply(to: items)
        #expect(kept.count == 1)
        // Quality counts apply only the codec choice: both HEVC clips' buckets show, the H.264 one doesn't.
        #expect(facets.qualities.map(\.value) == [.uhd(.fps60), .uhd(.fps30)])
        // Codec counts apply only the quality choice: just the 4K60 clip.
        #expect(facets.codecs.map(\.value) == [.hevc])
        #expect(facets.codecs.map(\.count) == [1])
    }
}
