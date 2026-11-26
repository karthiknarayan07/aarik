import SwiftUI
import Testing

@testable import AppUI

/// Reduce Motion: the animation and the symbol bounce the Mac's round 2 motion adds both switch off.
@MainActor
struct MotionTests {
    @Test func animatesNormally() {
        #expect(Motion.animation(reduceMotion: false) == .smooth)
        #expect(Motion.animation(.smooth(duration: 0.15), reduceMotion: false) == .smooth(duration: 0.15))
    }

    @Test func reduceMotionRemovesEveryAnimation() {
        #expect(Motion.animation(reduceMotion: true) == nil)
        #expect(Motion.animation(.smooth(duration: 0.15), reduceMotion: true) == nil)
        #expect(Motion.animation(.bouncy, reduceMotion: true) == nil)
    }

    @Test func theBounceFollowsTheValueUnlessReduceMotionIsOn() {
        #expect(Motion.bounceTrigger(3, reduceMotion: false) == 3)
        #expect(Motion.bounceTrigger(4, reduceMotion: false) != Motion.bounceTrigger(3, reduceMotion: false))
        #expect(Motion.bounceTrigger(nil, reduceMotion: false) == 0)
        // With Reduce Motion the trigger never changes, so the symbol never bounces.
        #expect(Motion.bounceTrigger(3, reduceMotion: true) == 0)
        #expect(Motion.bounceTrigger(4, reduceMotion: true) == Motion.bounceTrigger(3, reduceMotion: true))
    }
}
