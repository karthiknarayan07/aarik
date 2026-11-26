import CoreGraphics
import Foundation
import LocalLibrary
import Testing

@testable import QuickRunService

@Suite struct ShrinkVideosMessageTests {
    @Test func notesFollowTheMessageInSentenceCase() {
        let message = ShrinkVideosOutcome.nothingMatched.message(adding: [
            "Couldn't read 1 of 3 videos.",
            "The save folder in Settings isn't available, so the videos went to Movies.",
        ])

        #expect(
            message == "No videos matched, so nothing was queued. Couldn't read 1 of 3 videos. "
                + "The save folder in Settings isn't available, so the videos went to Movies.")
        #expect(ShrinkVideosOutcome.needsVideos.message(adding: []) == ShrinkVideosOutcome.needsVideos.message)
    }

    @Test func resolutionsUseTheQualityBucketThresholds() {
        #expect(ShrinkResolution.uhd.includes(pixelSize: CGSize(width: 3840, height: 2160)))
        #expect(!ShrinkResolution.uhd.includes(pixelSize: CGSize(width: 1920, height: 1080)))
        #expect(ShrinkResolution.fullHD.includes(pixelSize: CGSize(width: 1080, height: 1920)))
        #expect(ResolutionClass(shortSide: 2160) == .uhd)
        #expect(ResolutionClass(shortSide: 2159) == .fullHD)
        #expect(ResolutionClass(shortSide: 0) == .unknown)
    }
}
