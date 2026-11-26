import AarikCore
import MediaEngine

extension AppModel {
    func makePressure() -> PressureCoordinator {
        PressureCoordinator(
            speed: speed, thermal: SystemThermalSource(), power: SystemPowerSource(), cores: SystemCoreCounts(),
            starter: SystemActivityStarter(),
            onChange: { [weak self] effect in self?.applyPressure(effect) })
    }

    /// Starts listening to the thermal state and the power source. Called before the queue starts, so a Mac that is
    /// already hot or low on battery never begins a video.
    func startPressure() async {
        QuitConfirmation.watchForPowerOff()
        pressure.start()
        // The hold is sent like any queue command; wait for it before the queue may start.
        await lastQueueCommand?.value
    }

    /// The Mac got hotter or cooler, the battery crossed a threshold, or the speed changed.
    private func applyPressure(_ effect: PressureEffect) {
        let held = effect.automaticPause != nil
        let limit = effect.concurrencyLimit
        send { queue in
            await queue.setAutomaticHold(held)
            await queue.setConcurrency(limit)
        }
        let previous = lastThrottle
        lastThrottle = Task {
            await previous?.value
            await DownscaleThrottle.apply(limit: effect.concurrencyLimit, background: effect.runsInBackground)
        }
        refreshQueuePause()
    }

    /// Recomputes the pause the user sees and the update gate sees, and holds the Mac awake while work is under way.
    /// An automatic pause counts as paused for the gate, like the user's: the waiting jobs are saved and the running
    /// one finishes first.
    func refreshQueuePause() {
        let pause = pressure.queueChanged(jobs: jobs, isPausedByUser: isQueuePaused)
        if queuePause != pause { queuePause = pause }
        relaunchGate.update(jobs: jobs, isQueuePaused: pause.isPaused)
    }
}
