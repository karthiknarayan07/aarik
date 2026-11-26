import Foundation
import Testing

@testable import ConvertUI

/// The compare slider's divider and where its frames come from; no real video is read.
@Suite struct BeforeAfterCompareTests {
    @Test func theDividerStartsInTheMiddleAndFollowsADrag() {
        var split = CompareSplit()
        #expect(split.fraction == 0.5)
        split.drag(to: 150, width: 600)
        #expect(split.fraction == 0.25)
        split.drag(to: 300, width: 0)
        #expect(split.fraction == 0.25, "a view with no width changes nothing")
    }

    @Test func theDividerNeverReachesAnEdge() {
        var split = CompareSplit()
        split.drag(to: -50, width: 600)
        #expect(split.fraction == CompareSplit.range.lowerBound)
        split.drag(to: 900, width: 600)
        #expect(split.fraction == CompareSplit.range.upperBound)
        #expect(CompareSplit(fraction: 7).fraction == CompareSplit.range.upperBound)
    }

    @Test func arrowKeysMoveItInSteps() {
        var split = CompareSplit()
        split.nudge(1)
        split.nudge(1)
        #expect(abs(split.fraction - 0.6) < 0.0001)
        split.nudge(-1)
        #expect(abs(split.fraction - 0.55) < 0.0001)
        for _ in 0..<40 { split.nudge(-1) }
        #expect(split.fraction == CompareSplit.range.lowerBound)
    }

    @Test func voiceOverHearsHowMuchIsTheOriginal() {
        #expect(CompareSplit(fraction: 0.25).spoken == "25 percent original")
    }

    @Test func framesComeFromTheMiddleOfTheClip() {
        #expect(CompareSplit.frameTime(duration: 40) == 20)
        #expect(CompareSplit.frameTime(duration: 0) == 0)
    }

    @Test func aMissingFileOrAnAddressGivesNoFrame() async {
        #expect(await CompareFrames.frame(of: URL(filePath: "/nonexistent/clip.mov")) == nil)
        #expect(await CompareFrames.frame(of: URL(string: "x-photos-asset:abc")!) == nil)
    }
}
