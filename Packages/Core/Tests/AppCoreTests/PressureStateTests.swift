import Testing

@testable import AppCore

private let eightCores = CoreCounts(active: 8, performance: 4)

private func battery(_ percent: Int?) -> PowerSnapshot { PowerSnapshot(onBattery: true, percent: percent) }

private func state(thermal: [ThermalLevel] = [], power: [PowerSnapshot] = [], speed: SpeedSetting = .balanced)
    -> PressureState
{
    var state = PressureState(speed: speed)
    for level in thermal { state.update(thermal: level) }
    for snapshot in power { state.update(power: snapshot) }
    return state
}

@Suite("Thermal pressure")
struct ThermalPressureTests {
    @Test func nominalAndFairDoNotPauseOrLimit() {
        for level in [ThermalLevel.nominal, .fair] {
            let state = state(thermal: [level])
            #expect(state.automaticPause == nil)
            #expect(state.concurrencyLimit(cores: eightCores) == 4)
        }
    }

    @Test func seriousLimitsToOneVideoWithoutPausing() {
        let state = state(thermal: [.serious])
        #expect(state.automaticPause == nil)
        #expect(state.concurrencyLimit(cores: eightCores) == 1)
    }

    @Test func criticalPauses() {
        let state = state(thermal: [.critical])
        #expect(state.automaticPause == .thermal)
        #expect(state.concurrencyLimit(cores: eightCores) == 1)
    }

    @Test func staysPausedWhileSeriousOnTheWayDown() {
        let state = state(thermal: [.critical, .serious])
        #expect(state.automaticPause == .thermal)
    }

    @Test(arguments: [ThermalLevel.fair, .nominal]) func resumesAtFairOrBetter(level: ThermalLevel) {
        let state = state(thermal: [.critical, .serious, level])
        #expect(state.automaticPause == nil)
        #expect(state.concurrencyLimit(cores: eightCores) == 4)
    }

    @Test func seriousOnTheWayUpIsNotAPause() {
        let state = state(thermal: [.nominal, .fair, .serious])
        #expect(state.automaticPause == nil)
    }

    @Test func criticalAfterSeriousPausesAgainAfterAResume() {
        var state = state(thermal: [.critical, .nominal])
        #expect(state.automaticPause == nil)
        state.update(thermal: .critical)
        #expect(state.automaticPause == .thermal)
    }

    @Test func mapsProcessInfoStates() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.fair) == .fair)
        #expect(ThermalLevel(.serious) == .serious)
        #expect(ThermalLevel(.critical) == .critical)
    }
}

@Suite("Battery pressure")
struct BatteryPressureTests {
    @Test func noChargeLevelEverPausesTheQueue() {
        for percent in [100, 50, 26, 21, 20, 7, 1] {
            #expect(state(power: [battery(percent)]).automaticPause == nil)
        }
        #expect(state(power: [battery(3), battery(2)]).effect(cores: eightCores).automaticPause == nil)
    }

    @Test func lowPowerModeNeverPausesTheQueue() {
        let lowPower = PowerSnapshot(onBattery: true, percent: 5, isLowPowerMode: true)
        #expect(state(power: [lowPower]).automaticPause == nil)
    }

    @Test func warnsAtTwentyPercentOrLess() {
        #expect(state(power: [battery(21)]).isBatteryLow == false)
        #expect(state(power: [battery(20)]).isBatteryLow)
        #expect(state(power: [battery(7)]).isBatteryLow)
    }

    @Test func keepsWarningBetweenTwentyAndTwentyFivePercent() {
        for percent in [21, 24, 25] {
            #expect(state(power: [battery(19), battery(percent)]).isBatteryLow)
        }
    }

    @Test func warningClearsAboveTwentyFivePercent() {
        #expect(state(power: [battery(20), battery(26)]).isBatteryLow == false)
    }

    @Test func warningClearsWhenPluggedInAtAnyCharge() {
        let plugged = PowerSnapshot(onBattery: false, percent: 5)
        #expect(state(power: [battery(15), plugged]).isBatteryLow == false)
    }

    @Test func pluggedInOrNoBatteryNeverWarns() {
        #expect(state(power: [PowerSnapshot(onBattery: false, percent: 3)]).isBatteryLow == false)
        #expect(state(power: [battery(nil)]).isBatteryLow == false)
        #expect(state(power: [.pluggedIn]).isBatteryLow == false)
    }
}

@Suite("Pressure combined")
struct CombinedPressureTests {
    @Test func heatPausesEvenWithALowBattery() {
        let state = state(thermal: [.critical], power: [battery(10)])
        #expect(state.automaticPause == .thermal)
        #expect(state.isBatteryLow)
    }

    @Test func aLowBatteryDoesNotKeepTheQueuePausedWhenHeatClears() {
        var state = state(thermal: [.critical], power: [battery(10)])
        state.update(thermal: .nominal)
        #expect(state.automaticPause == nil)
        #expect(state.isBatteryLow)
    }

    @Test func effectCarriesPauseLimitAndPriority() {
        let effect = state(thermal: [.critical], speed: .quiet).effect(cores: eightCores)
        #expect(effect == PressureEffect(automaticPause: .thermal, concurrencyLimit: 1, runsInBackground: true))
    }
}

@Suite("Speed setting")
struct SpeedSettingTests {
    @Test func defaultIsBalanced() {
        #expect(SpeedSetting.default == .balanced)
    }

    @Test func quietIsOneAtATimeAtBackgroundPriority() {
        let state = state(speed: .quiet)
        #expect(state.concurrencyLimit(cores: eightCores) == 1)
        #expect(state.effect(cores: eightCores).runsInBackground)
    }

    @Test func balancedIsHalfTheCoresAtLeastTwo() {
        let state = state(speed: .balanced)
        #expect(state.concurrencyLimit(cores: CoreCounts(active: 10, performance: 6)) == 5)
        #expect(state.concurrencyLimit(cores: CoreCounts(active: 2, performance: 2)) == 2)
        #expect(state.concurrencyLimit(cores: CoreCounts(active: 1, performance: 1)) == 2)
        #expect(!state.effect(cores: eightCores).runsInBackground)
    }

    @Test func fastestIsAllPerformanceCores() {
        let state = state(speed: .fastest)
        #expect(state.concurrencyLimit(cores: CoreCounts(active: 14, performance: 10)) == 10)
        #expect(state.concurrencyLimit(cores: CoreCounts(active: 8, performance: 8)) == 8)
        #expect(!state.effect(cores: eightCores).runsInBackground)
    }

    @Test func fastestIsNeverBelowBalancedOnRealLayouts() {
        // (active, performance): M3 4P+4E, M4 4P+6E, M4 Pro 10P+4E, M3 Max 12P+4E, M1 Ultra 16P+4E.
        let layouts: [(CoreCounts, balanced: Int, fastest: Int)] = [
            (CoreCounts(active: 8, performance: 4), 4, 4),
            (CoreCounts(active: 10, performance: 4), 5, 5),
            (CoreCounts(active: 14, performance: 10), 7, 10),
            (CoreCounts(active: 16, performance: 12), 8, 12),
            (CoreCounts(active: 20, performance: 16), 10, 16),
        ]
        for layout in layouts {
            #expect(state(speed: .balanced).concurrencyLimit(cores: layout.0) == layout.balanced)
            #expect(state(speed: .fastest).concurrencyLimit(cores: layout.0) == layout.fastest)
            #expect(state(speed: .quiet).concurrencyLimit(cores: layout.0) == 1)
        }
    }

    @Test func fastestNeverExceedsTheActiveCores() {
        // Cores switched off: fewer active than performance cores.
        let limited = CoreCounts(active: 3, performance: 4)
        #expect(state(speed: .fastest).concurrencyLimit(cores: limited) == 3)
    }

    @Test(arguments: SpeedSetting.allCases) func seriousHeatLimitsEverySpeedToOne(speed: SpeedSetting) {
        #expect(state(thermal: [.serious], speed: speed).concurrencyLimit(cores: eightCores) == 1)
    }

    @Test func everyOptionHasATitleAndAOneLineSentenceCaseSummary() {
        for speed in SpeedSetting.allCases {
            #expect(!speed.title.isEmpty)
            #expect(speed.summary.hasSuffix("."))
            #expect(!speed.summary.contains("\n"))
        }
        #expect(SpeedSetting.allCases.map(\.title) == ["Quiet", "Balanced", "Fastest"])
    }

    @Test func coreCountsNeverDropBelowOne() {
        #expect(CoreCounts(active: 0, performance: 0) == CoreCounts(active: 1, performance: 1))
    }

    @Test func systemCoreCountsAreSane() {
        let counts = SystemCoreCounts().counts
        #expect(counts.active >= 1)
        #expect(counts.performance >= 1)
        #expect(counts.performance <= counts.active)
    }
}

@Suite("Queue pause reasons")
struct QueuePauseTests {
    @Test func runningHasNoReason() {
        let pause = QueuePause(isPausedByUser: false, automatic: nil)
        #expect(!pause.isPaused)
        #expect(pause.statusText == nil)
    }

    @Test func userPauseSaysPaused() {
        let pause = QueuePause(isPausedByUser: true, automatic: nil)
        #expect(pause.isPaused)
        #expect(pause.reason == .user)
        #expect(pause.statusText == "Paused")
    }

    @Test func automaticPausesSayWhy() {
        #if os(iOS)
            let cooling = "Paused while your device cools down"
        #else
            let cooling = "Paused while your Mac cools down"
        #endif
        #expect(QueuePause(isPausedByUser: false, automatic: .thermal).statusText == cooling)
    }

    @Test func aLowBatteryWarnsAndDoesNotPause() {
        let low = QueuePause(isPausedByUser: false, automatic: nil, lowBattery: true)
        #expect(!low.isPaused)
        #expect(low.reason == nil)
        #expect(low.statusText == nil)
        #expect(low.warningText == "Battery is low. Converting uses more power.")
        #expect(QueuePause(isPausedByUser: false, automatic: nil).warningText == nil)
    }

    @Test func aUserPauseOutranksAnAutomaticOne() {
        let pause = QueuePause(isPausedByUser: true, automatic: .thermal)
        #expect(pause.reason == .user)
        #expect(pause.statusText == "Paused")
    }

    @Test func liftingTheAutomaticPauseKeepsTheUsers() {
        let pause = QueuePause(isPausedByUser: true, automatic: nil)
        #expect(pause.isPaused)
    }
}

@Suite("Low Power Mode")
struct LowPowerModePressureTests {
    @Test func lowPowerModeLimitsToOneSlot() {
        for speed in SpeedSetting.allCases {
            let normal = state(speed: speed)
            let lowPower = state(
                power: [PowerSnapshot(onBattery: false, percent: nil, isLowPowerMode: true)], speed: speed)
            #expect(normal.concurrencyLimit(cores: eightCores) >= 1)
            #expect(lowPower.concurrencyLimit(cores: eightCores) == 1)
            #expect(lowPower.automaticPause == nil)
        }
    }

    @Test func leavingLowPowerModeRestoresTheSpeedsLimit() {
        var state = state(power: [PowerSnapshot(onBattery: false, percent: nil, isLowPowerMode: true)])
        state.update(power: .pluggedIn)
        #expect(state.concurrencyLimit(cores: eightCores) == 4)
    }
}
