# Stability

How the app keeps long batches and user files safe. Every rule here is enforced in code and most are covered by tests (the
Time Machine exclusion and the system inputs themselves are not; "planned" items belong to Plan 6 Phase B and do
not exist yet. Change a rule only together with its test.

## File safety (never break these)

1. **Originals are never deleted or overwritten.** The only way an original leaves its place is Replace, which moves
   it to the Trash (`DownscaleRunner.replace`, `FileManager.trashItem`). There is no permanent delete anywhere.
2. **Atomic output** (`MediaEngine/Downscale/AtomicOutput.swift`). The encoder writes
   `.<name>.partial-<UUID>` next to the final path (same volume) and renames it into place with
   `renamex_np(RENAME_EXCL)`, so a half-written file is never visible at the final name and an existing file is
   never replaced (`DownscaleError.outputExists`). Volumes without `RENAME_EXCL` fall back to an exclusive
   create plus rename.
3. **No partial files left behind.** On failure or cancellation the partial is removed. Stale partials from a
   crash are cleaned by name (UUID suffix must parse) in `DownscaleRunner.removeStalePartials`.
4. **Verify before Replace** (`DownscaleRunner.run`). An output is kept only if it is at least 10 % smaller; its
   metadata is read back and diffed against the source (`MetadataDiff`). Replace happens only when there are no
   warnings, the source is still the same file (`FileIdentity`), the optional originals backup was written and
   checked, and the original reached the Trash. Anything else keeps both files and completes the job with a note.
5. **Silent loss is refused.** Losses beyond what the planner predicted and showed to the user make the job
   "kept as is", and the output is removed.
6. **Work folder containment** (`PhotosLibrary/WorkFolder.swift`). Photos input is written only to
   `<Application Support>/<bundle id>/Work/<job id>/`. Every removal is checked to be strictly inside `Work`
   (symlinks and `..` resolved), never `Work` itself. The folder is removed on every exit path, swept at launch
   before the queue starts, and excluded from Time Machine.
7. **Photos: the owner's assets are read-only inputs.** `PhotoInputFetcher` only reads them. The one write is
   `PhotoSaver`: a single `performChanges` adds one new asset (`PhotoKitStore.saveVideo`), then the saver reads
   it back and checks length, size, a non-empty file, date and location against the source. On a mismatch the new
   asset is deleted again (`PhotoSaveError.verifyFailed` with its `Cleanup`). A source asset is never edited. The
   only delete API is `PhotoKitStore.deleteAssets`, one change that goes through the system's own confirmation
   (declining is reported, not forced). The one caller for an original is `OriginalsDeleter`: after Replace jobs
   finish, or when the user presses the pending-deletion bar's button, it deletes every original in
   `PendingDeletions` in a single call. An original is recorded there only after its copy is saved and verified (and
   its backup, when on, is written). Declining keeps the list and nothing asks again by itself until the next run
   ends. "Moved" rests on the delete succeeding and the id no longer fetching (PhotoKit can't list Recently Deleted).
   A job put back in the queue after its copy was saved (crash, quit) finds its `SavedCopy` marker in
   `PendingDeletions` and never saves a second copy; a backup written in a run that is then cancelled is removed
   again. Package tests use `FakePhotoStore` and never touch the real library; the only code that does is the
   DEBUG-only `PhotosSpike` (launch argument), not shipped.
8. **Persisted queue is never overwritten blindly** (`AppCore/Jobs/JobStore.swift`). `jobs.json` is written
   atomically; an unreadable file is moved to `jobs.json.corrupt-<time>`, or, if that fails, left alone and
   the session's queue is not saved (`mustNotSave`).

## Cancellation and quitting

- Jobs run in a `Task`; encoding checks cancellation and stops, removing its partial. Cancelling a job removes it
  from the queue; the original is untouched.
- `JobQueue` runs one job at a time and persists after every state change. A job found `running` at launch
  (crash, quit) is put back to `queued`.
- `applicationShouldTerminate` first asks "Stop converting and quit?" (a standard `NSAlert`, default button
  "Stop and Quit", `QuitConfirmation`) when work is under way, using `QuitPolicy.needsConfirmation` (the same
  definition of busy as `RelaunchGate`: a job running, or waiting jobs about to start). It does not ask when the queue
  is idle or paused with nothing running, nor while the system is logging out, restarting or shutting down (the quit
  Apple event's `kAEQuitReason`, or a `NSWorkspace.willPowerOffNotification` in the last 30 seconds, cleared when the app
  becomes active again; either signal is enough, `QuitPolicy.isSessionEnding`): then it quits without asking.
- After the answer, it replies later: pending library saves finish and the running job is returned to the queue
  (`AppModel.prepareForTermination` -> `JobQueue.shutdown`) before the app exits. The encoder removes its partial
  file when cancelled, and every job, the interrupted one and the rest, is saved as `queued`
  (`quittingKeepsTheRunningJobAndTheRestOfTheQueueForNextLaunch`); Photos input in `Work/` is cleared by the next
  launch's sweep. They continue at the next launch (when auto-start is on).

## Updates (Sparkle)

- The updater starts only when the build has a feed URL and a public key; Debug builds never touch the network.
- Installing never interrupts work: `Updater` delegates to `RelaunchGate` (`AppCore/Jobs/RelaunchGate.swift`).
  The relaunch after an update is held while a job is running, or jobs are waiting and the queue is not paused,
  and runs once when the queue goes idle. A paused queue counts as idle: the user paused on purpose, and waiting
  jobs are saved after every change (`jobs.json`) and restored as queued at next launch, where they start when the
  queue is resumed (automatically, unless auto-start is off). An automatic pause (heat, low battery) counts as paused
  in the same way, because the gate is fed the combined pause (`QueuePause.isPaused`): a running job still holds the
  relaunch, waiting jobs do not. The choice: holding an update for as long as the Mac stays hot or on a low battery
  could be indefinite, and nothing is lost by relaunching, since the queue is saved and the automatic pause is
  decided again at launch from the thermal state and the battery.
  Tests: `RelaunchGateTests`.

## Resources

- Heavy work is bounded: `WorkSlots` (half the cores, at least 2) limits concurrent downscales; blocking reads run
  on a dedicated executor, never the shared pool.
- Disk space preflight: **planned** (Plan 6 B1). Until then a full disk surfaces as a failed job, with the partial
  removed.

## Sleep, heat and battery

The decisions are pure types in `AppCore/Pressure` (`PressureState`, `QueuePause`, `QuitPolicy`); the system inputs
(thermal state, IOPowerSources, core counts, the power assertion) sit behind protocols with fakes in the tests
(`PressureCoordinator`).

- **Sleep.** While work is under way (a job running, or waiting jobs and the queue not paused) the app holds
  `ProcessInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled])`, once, and ends it when the queue is
  idle or paused with nothing running. The display may sleep; the system may not. A running job finishing after a
  pause keeps the hold until it is done.
- **Heat.** `.serious`: one video at a time. `.critical`: the queue pauses after the current video, status line
  "Paused while your Mac cools down". It resumes at `.fair` or better (`.serious` on the way down stays paused).
- **Battery.** Conversion continues on battery. At 20 % or less the queue pauses after the current video ("Paused:
  battery low"); it resumes when the Mac is plugged in or above 25 %. No battery reading means never paused.
- **Pause reasons stay separate.** `JobQueue` has the user's pause (`pause`/`resume`) and its own automatic hold
  (`setAutomaticHold`). `resume()` never lifts the hold, and lifting it never overrides the user's pause. The status
  line shows the user's pause first ("Paused"), otherwise the automatic reason.
- **Speed** (Settings, Quiet / Balanced / Fastest): see PERFORMANCE.md.

## Diagnostics and CI

- Swift 6 strict concurrency, warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`, and
  `-Xswiftc -warnings-as-errors` for the packages in CI).
- CI runs `swift test --sanitize=thread` and `--sanitize=address` as separate jobs.
- The shared scheme enables Main Thread Checker and Thread Performance Checker for Run and Test.
- Logging uses `os.Logger` (subsystem is the bundle id, category per area, e.g. `queue`). Don't put file names or
  paths in log lines that persist.
