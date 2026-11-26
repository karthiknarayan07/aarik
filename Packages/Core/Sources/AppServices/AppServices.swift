import AppCore
import Assistant
import Foundation
import LocalLibrary
import MediaEngine
import Observation
import PhotosLibrary

/// The shared toolbox every tool works with (ADR 0006): the one job queue, the pressure rules, the settings, the
/// originals waiting to leave Photos, the staging folder, the library service and the Assistant client. A tool has
/// its own observable model (`ConvertModel(services:)`) and registers its runners here; there is no generic app state.
///
/// The shell is the composition root: it builds this, then each tool, then each tool's scene.
@MainActor
@Observable
public final class AppServices {
    // MARK: Shared pieces

    /// The folder the app keeps its saved queue, library list and staging in.
    @ObservationIgnored public let directory: URL
    @ObservationIgnored public let defaults: UserDefaults
    @ObservationIgnored public let settings: SettingsStore
    /// Every tool's jobs. Tools register their runners with `register(_:)`; jobs of a tool this build doesn't have
    /// stay in the saved queue untouched.
    @ObservationIgnored public let queue: JobQueue
    @ObservationIgnored public let library: LibraryService
    /// Photos originals whose copy is saved and verified, waiting for the batch delete.
    @ObservationIgnored public let pendingDeletions: PendingDeletions
    /// The Overview's last savings numbers, kept in a SwiftData store in `directory` so the page draws at once.
    @ObservationIgnored public let savingsStats: SavingsStatsCache
    /// The app's own copies of inputs that reached an action as data only. Not the Photos Work folder: that one is
    /// swept at every launch, this one keeps what a queued job still reads.
    @ObservationIgnored public let staging: StagedInputs
    /// The on-device language model every assistant feature goes through.
    @ObservationIgnored public let assistantClient: any LanguageModelClient
    /// Holds an update's relaunch while a job runs or jobs are waiting; the updater asks it, the queue feeds it.
    @ObservationIgnored public let relaunchGate = RelaunchGate()
    /// Reads the thermal state and power source, keeps the device awake while the queue works, and tells the queue and
    /// the downscale limit what to do.
    @ObservationIgnored public lazy var pressure = makePressure()

    // MARK: Queue state

    /// The queue's jobs, mirrored for the views.
    public private(set) var jobs: [Job] = []
    /// Counts, saved total and running progress for the Activity rows, updated with `jobs`.
    public private(set) var activity = ActivitySummary(jobs: [])
    /// The user's pause (the Pause button, auto-start off). The queue is also held, apart from this, while the device
    /// is hot or the battery is low: see `queuePause`.
    public var isQueuePaused: Bool {
        didSet { refreshQueuePause() }
    }
    /// Whether the queue is paused and why, user and automatic together; its `statusText` is the status line.
    public private(set) var queuePause = QueuePause(isPausedByUser: false, automatic: nil)
    /// How hard conversion works (Settings); thermal rules apply on top.
    public var speed: SpeedSetting {
        didSet {
            settings.speed = speed
            pressure.setSpeed(speed)
        }
    }
    /// Set when the saved queue couldn't be read; the shell tells the person once.
    public private(set) var queueLoadError: String?

    // MARK: Plumbing

    @ObservationIgnored private var lastThrottle: Task<Void, Never>?
    /// The last command sent to the queue; each new one waits for it, so commands arrive in the order given.
    @ObservationIgnored private var lastQueueCommand: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    /// Set once `start()` has finished; entry points that arrive earlier (an intent that launched the app) wait.
    @ObservationIgnored private var hasFinishedStarting = false
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// The saved queue couldn't be read, so its job list is incomplete and saved copies are not pruned by it.
    @ObservationIgnored private var queueLoadFailed = false
    @ObservationIgnored private var runTracker = QueueRunTracker()
    /// Staged copies whose jobs are queued; each is removed once none of its jobs is pending.
    @ObservationIgnored private var stagedWatch: Set<URL> = []
    @ObservationIgnored private var jobObservers: [@MainActor ([Job]) -> Void] = []
    @ObservationIgnored private var runObservers: [@MainActor (QueueRunSummary) -> Void] = []
    /// The jobs a run's own summary leaves out (a quick run announces itself): the shell sets it.
    @ObservationIgnored public var jobsExcludedFromRunSummary: @MainActor () -> Set<UUID> = { [] }

    /// Application Support/<bundle id>. `override` is a folder that keeps a test launch away from the real library and
    /// queue; the shell passes it from the launch arguments in Debug builds only.
    public nonisolated static func supportDirectory(bundleIdentifier: String?, override: URL? = nil) -> URL {
        if let override { return override }
        let id = bundleIdentifier ?? ProcessInfo.processInfo.processName
        return URL.applicationSupportDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    /// The staging folder's name inside the support directory.
    public nonisolated static let stagingFolderName = "Staging"

    public init(
        directory: URL, defaults: UserDefaults = .standard, photoStore: any PhotoStore = PhotoKitStore(),
        assistantClient: any LanguageModelClient = .real
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore(defaults)
        self.directory = directory
        self.defaults = defaults
        self.settings = settings
        self.speed = settings.speed
        self.assistantClient = assistantClient
        self.staging = StagedInputs(
            directory: directory.appending(path: Self.stagingFolderName, directoryHint: .isDirectory))
        self.library = LibraryService(directory: directory, photoStore: photoStore)
        self.pendingDeletions = PendingDeletions(directory: directory)
        self.savingsStats = SavingsStatsCache(store: SwiftDataSavingsStatsStore(directory: directory))
        // With auto-start off the queue is paused from the start, so no enqueue can slip in before a pause.
        let autoStart = settings.autoStartQueue
        self.isQueuePaused = !autoStart
        self.queue = JobQueue(store: JobStore(directory: directory), runners: [:], startPaused: !autoStart)
    }

    // MARK: Tools

    /// Registers the runner of each of the tool's job kinds. Call it before `start()`.
    public func register(_ tool: any Tool) {
        for kind in tool.jobKinds {
            if let runner = tool.runner(for: kind) { queue.register(runner, forToolID: kind.toolID) }
        }
    }

    /// Called with the jobs after every change to the queue.
    public func observeJobs(_ handler: @escaping @MainActor ([Job]) -> Void) {
        jobObservers.append(handler)
    }

    /// Called once when a run ends: nothing is queued or running any more after at least one job finished.
    public func observeRunFinished(_ handler: @escaping @MainActor (QueueRunSummary) -> Void) {
        runObservers.append(handler)
    }

    // MARK: Lifecycle

    /// Starts the pressure rules and mirrors the queue's jobs, then starts the queue unless it was created paused
    /// (auto-start off). Safe to call more than once.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await startPressure()
        let queue = self.queue
        let loadError = await queue.loadError
        queueLoadFailed = loadError != nil
        queueLoadError = loadError
        updatesTask = Task { [weak self] in
            for await jobs in await queue.updates() {
                self?.receive(jobs)
            }
        }
        // Copies of action inputs that no waiting job reads are left over from a crash or quit.
        let stillRead = await queue.jobs.filter(StagedInputs.isNeeded(by:)).map(\.source)
        let staging = self.staging
        await Task.detached(priority: .utility) { staging.sweep(keeping: stillRead) }.value
        // A queue created paused (auto-start off) waits for Resume.
        if !isQueuePaused { await queue.resume() }
        hasFinishedStarting = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once `start()` has finished: the work-folder sweep is done and the queue is running, so what an
    /// entry point adds can't start a job too early.
    public func waitUntilStarted() async {
        guard !hasFinishedStarting else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    /// Lets queued commands finish and stops the queue before the app quits. The running job goes back to the queue
    /// and starts over next launch.
    public func prepareForTermination() async {
        await lastQueueCommand?.value
        await queue.shutdown()
        updatesTask?.cancel()
    }

    /// Pauses the queue and cancels running jobs so their partial output is discarded and they return to `.queued`.
    public func pauseForBackgroundExpiration() async {
        isQueuePaused = true
        let previous = lastQueueCommand
        let queue = self.queue
        let command = Task {
            await previous?.value
            await queue.pauseAndRequeueRunning()
        }
        lastQueueCommand = command
        await command.value
    }

    // MARK: Queue commands

    /// Sends a command to the queue after the previous one.
    public func send(_ command: @escaping @Sendable (JobQueue) async -> Void) {
        let previous = lastQueueCommand
        let queue = self.queue
        lastQueueCommand = Task {
            await previous?.value
            await command(queue)
        }
    }

    /// Returns once every command sent so far has reached the queue.
    public func waitForQueueCommands() async {
        await lastQueueCommand?.value
    }

    public func toggleQueuePaused() {
        let pause = !isQueuePaused
        isQueuePaused = pause
        send { queue in
            if pause { await queue.pause() } else { await queue.resume() }
        }
    }

    public func remove(_ job: Job) {
        let id = job.id
        send { await $0.remove(id) }
    }

    /// Stops the job if it is converting (its partial file is removed, the original untouched) and takes it out
    /// of the queue.
    public func cancel(_ job: Job) {
        let id = job.id
        send { await $0.cancel(id) }
    }

    /// Empties the queue and stops the conversion in progress.
    public func cancelAll() {
        send { await $0.cancelAll() }
    }

    public func retry(_ job: Job) {
        let id = job.id
        send { await $0.retry(id) }
    }

    public func retryAllFailed() {
        send { await $0.retryAllFailed() }
    }

    // MARK: Staging

    /// Keeps these staged copies until none of their jobs is pending.
    public func watchStaged(_ urls: some Sequence<URL>) {
        stagedWatch.formUnion(urls)
    }

    /// Removes the copies no job needs any more (finished, kept as is, cancelled, or a failed job taken out of the
    /// queue); a failed job keeps its copy so Retry works. The queue itself is asked, so a job just added is never
    /// missed.
    public func releaseStagedInputs() async {
        stagedWatch = staging.release(watching: stagedWatch, jobs: await queue.jobs)
    }

    // MARK: Pressure

    private func makePressure() -> PressureCoordinator {
        PressureCoordinator(
            speed: speed, thermal: SystemThermalSource(), power: SystemPowerSource(), cores: SystemCoreCounts(),
            starter: SystemActivityStarter(),
            onChange: { [weak self] effect in self?.applyPressure(effect) })
    }

    /// Starts listening to the thermal state and the power source. Called before the queue starts, so a device that is
    /// already hot or low on battery never begins a job.
    private func startPressure() async {
        pressure.start()
        // The hold is sent like any queue command; wait for it before the queue may start.
        await lastQueueCommand?.value
    }

    /// The device got hotter or cooler, the battery crossed a threshold, or the speed changed.
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

    /// Recomputes the pause the user sees and the update gate sees, and holds the device awake while work is under way.
    /// An automatic pause counts as paused for the gate, like the user's: the waiting jobs are saved and the running
    /// one finishes first.
    private func refreshQueuePause() {
        let pause = pressure.queueChanged(jobs: jobs, isPausedByUser: isQueuePaused)
        if queuePause != pause { queuePause = pause }
        relaunchGate.update(jobs: jobs, isQueuePaused: pause.isPaused)
    }

    // MARK: Queue updates

    private func receive(_ jobs: [Job]) {
        self.jobs = jobs
        refreshQueuePause()
        activity = ActivitySummary(jobs: jobs)
        // A saved copy is only needed while its job can still be put back in the queue.
        if !queueLoadFailed {
            pendingDeletions.keepSavedCopies(
                forJobs: Set(
                    jobs.filter { job in
                        switch job.state {
                        case .completed, .keptAsIs: false
                        case .queued, .running, .failed: true
                        }
                    }.map(\.id)))
        }
        for observer in jobObservers { observer(jobs) }
        // A quick run announces itself; the generic summary is for the window's jobs.
        let excluded = jobsExcludedFromRunSummary()
        let windowJobs = excluded.isEmpty ? jobs : jobs.filter { !excluded.contains($0.id) }
        if let summary = runTracker.observe(windowJobs) {
            for observer in runObservers { observer(summary) }
        }
        if !stagedWatch.isEmpty { Task { await releaseStagedInputs() } }
    }
}
