import Foundation

/// Joins the system inputs (thermal state, power source, core counts) to the decisions in `PressureState`, and keeps the
/// Mac awake while the queue works. `onChange` runs with the new effect (at `start`, then whenever it differs): the
/// app applies it to the queue's automatic pause and to the downscale limit.
@MainActor
public final class PressureCoordinator {
    public private(set) var state: PressureState
    public private(set) var effect: PressureEffect
    private let thermal: any ThermalSource
    private let power: any PowerSource
    private let cores: any CoreCounting
    private let starter: any ActivityStarter
    private let onChange: @MainActor (PressureEffect) -> Void
    private var activity: (any ActivityToken)?
    private var isStarted = false

    public init(
        speed: SpeedSetting, thermal: any ThermalSource, power: any PowerSource, cores: any CoreCounting,
        starter: any ActivityStarter, onChange: @escaping @MainActor (PressureEffect) -> Void
    ) {
        state = PressureState(speed: speed)
        effect = state.effect(cores: cores.counts)
        self.thermal = thermal
        self.power = power
        self.cores = cores
        self.starter = starter
        self.onChange = onChange
    }

    /// Reads the inputs, starts listening, and reports the first effect.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        state.update(thermal: thermal.level)
        state.update(power: power.snapshot)
        thermal.observe { [weak self] in self?.thermalChanged() }
        power.observe { [weak self] in self?.powerChanged() }
        effect = state.effect(cores: cores.counts)
        onChange(effect)
    }

    public func setSpeed(_ speed: SpeedSetting) {
        state.speed = speed
        refresh()
    }

    /// Records the queue's jobs and the user's pause: holds the system awake while work is under way, and returns the
    /// pause to show. Call it after every change to the jobs or to the user's pause.
    @discardableResult
    public func queueChanged(jobs: [Job], isPausedByUser: Bool) -> QueuePause {
        let pause = self.pause(isPausedByUser: isPausedByUser)
        setAwake(RelaunchGate.isBusy(jobs: jobs, isQueuePaused: pause.isPaused))
        return pause
    }

    public func pause(isPausedByUser: Bool) -> QueuePause {
        QueuePause(isPausedByUser: isPausedByUser, automatic: effect.automaticPause, lowBattery: effect.lowBattery)
    }

    private func thermalChanged() {
        state.update(thermal: thermal.level)
        refresh()
    }

    private func powerChanged() {
        state.update(power: power.snapshot)
        refresh()
    }

    private func refresh() {
        let new = state.effect(cores: cores.counts)
        guard new != effect else { return }
        effect = new
        onChange(new)
    }

    private func setAwake(_ awake: Bool) {
        if awake {
            if activity == nil { activity = starter.begin(reason: "Converting videos") }
        } else {
            activity?.end()
            activity = nil
        }
    }
}
