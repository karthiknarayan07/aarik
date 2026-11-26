import AppCore
import Testing

@testable import iOSApp

/// A hand-off from the share extension or an intent waits until the app is showing the tabs, then opens once.
struct HandoffGateTests {
    private static let queue = ToolRoute(toolID: "convert", page: "queue")

    @Test func nothingStagedGivesNothing() {
        var gate = HandoffGate()
        #expect(gate.take(hasOnboarded: true, hasRestored: true) == nil)
    }

    @Test func waitsWhileTheOnboardingIsShowing() {
        var gate = HandoffGate()
        gate.stage(Self.queue)
        #expect(gate.take(hasOnboarded: false, hasRestored: true) == nil)
        #expect(gate.pending == Self.queue)
        // Finishing the onboarding releases it.
        #expect(gate.take(hasOnboarded: true, hasRestored: true) == Self.queue)
        #expect(gate.pending == nil)
    }

    @Test func waitsForTheRestoredTabAndStackOnAColdLaunch() {
        var gate = HandoffGate()
        gate.stage(Self.queue)
        #expect(gate.take(hasOnboarded: true, hasRestored: false) == nil)
        #expect(gate.pending == Self.queue)
        #expect(gate.take(hasOnboarded: true, hasRestored: true) == Self.queue)
    }

    @Test func opensOnceOnly() {
        var gate = HandoffGate()
        gate.stage(Self.queue)
        #expect(gate.take(hasOnboarded: true, hasRestored: true) == Self.queue)
        #expect(gate.take(hasOnboarded: true, hasRestored: true) == nil)
    }

    @Test func aNewerHandoffReplacesOneNotShownYet() {
        var gate = HandoffGate()
        gate.stage(ToolRoute(toolID: "convert", page: "photos"))
        gate.stage(Self.queue)
        #expect(gate.take(hasOnboarded: false, hasRestored: true) == nil)
        #expect(gate.take(hasOnboarded: true, hasRestored: true) == Self.queue)
    }
}
