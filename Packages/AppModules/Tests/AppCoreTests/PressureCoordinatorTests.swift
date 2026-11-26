import Foundation
import Testing

@testable import AppCore

@MainActor
private final class FakeThermal: ThermalSource {
    var level = ThermalLevel.nominal
    private var handler: (@MainActor () -> Void)?
    func observe(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    func set(_ level: ThermalLevel) {
        self.level = level
        handler?()
    }
}

@MainActor
private final class FakePower: PowerSource {
    var snapshot = PowerSnapshot.pluggedIn
    private var handler: (@MainActor () -> Void)?
    func observe(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    func set(_ snapshot: PowerSnapshot) {
        self.snapshot = snapshot
        handler?()
    }
}

private struct FakeCores: CoreCounting {
    var counts = CoreCounts(active: 8, performance: 4)
}

@MainActor
private final class FakeStarter: ActivityStarter {
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var reasons: [String] = []
    var isHeld: Bool { begun > ended }

    func begin(reason: String) -> any ActivityToken {
        begun += 1
        reasons.append(reason)
        return Token(self)
    }

    private final class Token: ActivityToken {
        let owner: FakeStarter
        init(_ owner: FakeStarter) { self.owner = owner }
        func end() { owner.ended += 1 }
    }
}

private func job(_ state: JobState) -> Job {
    Job(
        toolID: "fake", source: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"), sourceBookmark: Data(),
        settings: Data(), state: state)
}

@MainActor
private struct Rig {
    let thermal = FakeThermal()
    let power = FakePower()
    let starter = FakeStarter()
    let coordinator: PressureCoordinator
    let effects: Effects

    @MainActor final class Effects {
        var all: [PressureEffect] = []
    }

    init(speed: SpeedSetting = .balanced) {
        let effects = Effects()
        self.effects = effects
        coordinator = PressureCoordinator(
            speed: speed, thermal: thermal, power: power, cores: FakeCores(), starter: starter,
            onChange: { effects.all.append($0) })
        coordinator.start()
    }
}

@MainActor
@Suite("Pressure coordinator")
struct PressureCoordinatorTests {
    @Test func startReportsTheFirstEffect() {
        let rig = Rig()
        #expect(rig.effects.all == [PressureEffect(automaticPause: nil, concurrencyLimit: 4, runsInBackground: false)])
    }

    @Test func startReadsTheCurrentInputs() {
        let thermal = FakeThermal()
        thermal.level = .critical
        let effects = Rig.Effects()
        let coordinator = PressureCoordinator(
            speed: .balanced, thermal: thermal, power: FakePower(), cores: FakeCores(), starter: FakeStarter(),
            onChange: { effects.all.append($0) })
        coordinator.start()
        #expect(effects.all.last?.automaticPause == .thermal)
    }

    @Test func criticalHeatPausesAndFairResumes() {
        let rig = Rig()
        rig.thermal.set(.critical)
        #expect(rig.effects.all.last?.automaticPause == .thermal)
        rig.thermal.set(.serious)
        #expect(rig.effects.all.last?.automaticPause == .thermal)
        rig.thermal.set(.fair)
        #expect(
            rig.effects.all.last == PressureEffect(automaticPause: nil, concurrencyLimit: 4, runsInBackground: false))
    }

    @Test func seriousHeatLowersTheLimitAndNominalRestoresIt() {
        let rig = Rig(speed: .fastest)
        #expect(rig.effects.all.last?.concurrencyLimit == 4)
        rig.thermal.set(.serious)
        #expect(rig.effects.all.last?.concurrencyLimit == 1)
        rig.thermal.set(.nominal)
        #expect(rig.effects.all.last?.concurrencyLimit == 4)
    }

    @Test func batteryPausesAtTwentyAndResumesAboveTwentyFiveOrPluggedIn() {
        let rig = Rig()
        rig.power.set(PowerSnapshot(onBattery: true, percent: 20))
        #expect(rig.effects.all.last?.automaticPause == .batteryLow)
        rig.power.set(PowerSnapshot(onBattery: true, percent: 24))
        #expect(rig.effects.all.last?.automaticPause == .batteryLow)
        rig.power.set(PowerSnapshot(onBattery: true, percent: 26))
        #expect(rig.effects.all.last?.automaticPause == nil)
        rig.power.set(PowerSnapshot(onBattery: true, percent: 12))
        #expect(rig.effects.all.last?.automaticPause == .batteryLow)
        rig.power.set(PowerSnapshot(onBattery: false, percent: 12))
        #expect(rig.effects.all.last?.automaticPause == nil)
    }

    @Test func onlyRealChangesAreReported() {
        let rig = Rig()
        let before = rig.effects.all.count
        rig.thermal.set(.fair)
        rig.power.set(PowerSnapshot(onBattery: true, percent: 80))
        rig.power.set(PowerSnapshot(onBattery: true, percent: 79))
        #expect(rig.effects.all.count == before)
    }

    @Test func changingTheSpeedReportsANewLimitAndPriority() {
        let rig = Rig()
        rig.coordinator.setSpeed(.quiet)
        #expect(
            rig.effects.all.last == PressureEffect(automaticPause: nil, concurrencyLimit: 1, runsInBackground: true))
        rig.coordinator.setSpeed(.fastest)
        #expect(
            rig.effects.all.last == PressureEffect(automaticPause: nil, concurrencyLimit: 4, runsInBackground: false))
    }

    @Test func aSecondStartDoesNothing() {
        let rig = Rig()
        let before = rig.effects.all.count
        rig.coordinator.start()
        #expect(rig.effects.all.count == before)
    }

    // MARK: Pause reasons

    @Test func automaticResumeNeverOverridesTheUsersPause() {
        let rig = Rig()
        rig.thermal.set(.critical)
        let paused = rig.coordinator.pause(isPausedByUser: true)
        rig.thermal.set(.nominal)
        let afterCooling = rig.coordinator.pause(isPausedByUser: true)
        #expect(paused.reason == .user)
        #expect(afterCooling.isPaused)
        #expect(afterCooling.reason == .user)
        #expect(afterCooling.automatic == nil)
    }

    @Test func theUsersResumeDoesNotOverrideAnAutomaticPause() {
        let rig = Rig()
        rig.power.set(PowerSnapshot(onBattery: true, percent: 10))
        let pause = rig.coordinator.pause(isPausedByUser: false)
        #expect(pause.isPaused)
        #expect(pause.statusText == "Paused: battery low")
    }

    // MARK: Staying awake

    @Test func holdsTheSystemAwakeWhileAJobRuns() {
        let rig = Rig()
        rig.coordinator.queueChanged(jobs: [job(.running(progress: 0.1))], isPausedByUser: false)
        #expect(rig.starter.isHeld)
        #expect(rig.starter.reasons == ["Converting videos"])
    }

    @Test func holdsOnceNotOncePerUpdate() {
        let rig = Rig()
        let jobs = [job(.running(progress: 0.1)), job(.queued)]
        for _ in 0..<3 { rig.coordinator.queueChanged(jobs: jobs, isPausedByUser: false) }
        #expect(rig.starter.begun == 1)
    }

    @Test func releasesWhenTheQueueGoesIdle() {
        let rig = Rig()
        rig.coordinator.queueChanged(jobs: [job(.running(progress: 0.1))], isPausedByUser: false)
        rig.coordinator.queueChanged(jobs: [job(.failed(reason: "x"))], isPausedByUser: false)
        #expect(!rig.starter.isHeld)
        #expect(rig.starter.ended == 1)
    }

    @Test func releasesWhenPausedWithNothingRunning() {
        let rig = Rig()
        rig.coordinator.queueChanged(jobs: [job(.queued)], isPausedByUser: false)
        #expect(rig.starter.isHeld)
        rig.coordinator.queueChanged(jobs: [job(.queued)], isPausedByUser: true)
        #expect(!rig.starter.isHeld)
    }

    @Test func releasesWhenAutomaticallyPausedWithNothingRunning() {
        let rig = Rig()
        rig.coordinator.queueChanged(jobs: [job(.queued)], isPausedByUser: false)
        rig.thermal.set(.critical)
        rig.coordinator.queueChanged(jobs: [job(.queued)], isPausedByUser: false)
        #expect(!rig.starter.isHeld)
        rig.thermal.set(.nominal)
        rig.coordinator.queueChanged(jobs: [job(.queued)], isPausedByUser: false)
        #expect(rig.starter.isHeld)
        #expect(rig.starter.begun == 2)
    }

    @Test func keepsHoldingWhileTheRunningJobFinishesAfterAPause() {
        let rig = Rig()
        rig.coordinator.queueChanged(jobs: [job(.running(progress: 0.5)), job(.queued)], isPausedByUser: false)
        rig.coordinator.queueChanged(jobs: [job(.running(progress: 0.6)), job(.queued)], isPausedByUser: true)
        #expect(rig.starter.isHeld)
    }

    @Test func neverHoldsForAnEmptyQueue() {
        let rig = Rig()
        rig.coordinator.queueChanged(jobs: [], isPausedByUser: false)
        #expect(rig.starter.begun == 0)
    }

    // MARK: Update relaunch

    @Test func anAutomaticPauseCountsAsPausedForTheRelaunchGate() {
        // The gate treats a paused queue with only waiting jobs as idle; an automatic pause is such a pause.
        let rig = Rig()
        rig.thermal.set(.critical)
        let pause = rig.coordinator.pause(isPausedByUser: false)
        let jobs = [job(.queued)]
        #expect(RelaunchGate.isBusy(jobs: jobs, isQueuePaused: false))
        #expect(!RelaunchGate.isBusy(jobs: jobs, isQueuePaused: pause.isPaused))
        // A job still running when the pause starts holds the relaunch, as it does for a user pause.
        #expect(RelaunchGate.isBusy(jobs: [job(.running(progress: 0.5))], isQueuePaused: pause.isPaused))
    }
}
