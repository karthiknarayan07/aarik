# Stability

How the app keeps long batches and user files safe. Every rule here is enforced in code and covered by a test;
"planned" items belong to Plan 6 Phase B and do not exist yet. Change a rule only together with its test.

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
7. **Photos library is read-only today.** The app lists and fetches videos (`PhotoInputFetcher`); there is no code
   that writes to or deletes from the Photos library. Saving back to Photos is planned (Plan 3) and must keep
   the original until the saved copy is confirmed.
8. **Persisted queue is never overwritten blindly** (`AppCore/Jobs/JobStore.swift`). `jobs.json` is written
   atomically; an unreadable file is moved to `jobs.json.corrupt-<time>`, or, if that fails, left alone and
   the session's queue is not saved (`mustNotSave`).

## Cancellation and quitting

- Jobs run in a `Task`; encoding checks cancellation and stops, removing its partial. Cancelling a job removes it
  from the queue; the original is untouched.
- `JobQueue` runs one job at a time and persists after every state change. A job found `running` at launch
  (crash, quit) is put back to `queued`.
- `applicationShouldTerminate` replies later: pending library saves finish and the running job is returned to the
  queue (`AppModel.prepareForTermination` -> `JobQueue.shutdown`) before the app exits. A "Stop converting and
  quit?" confirmation is planned (B2).

## Updates (Sparkle)

- The updater starts only when the build has a feed URL and a public key; Debug builds never touch the network.
- Installing never interrupts work: `Updater` delegates to `RelaunchGate` (`AppCore/Jobs/RelaunchGate.swift`).
  The relaunch after an update is held while a job is running, or jobs are waiting and the queue is not paused,
  and runs once when the queue goes idle. A paused queue counts as idle (saved jobs resume next launch).
  Tests: `RelaunchGateTests`.

## Resources

- Heavy work is bounded: `WorkSlots` (half the cores, at least 2) limits concurrent downscales; blocking reads run
  on a dedicated executor, never the shared pool.
- Disk space preflight, sleep prevention during a batch and thermal throttling: **planned** (Plan 6 B1, B2). Until
  then a full disk surfaces as a failed job, with the partial removed.

## Diagnostics and CI

- Swift 6 strict concurrency, warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`, and
  `-Xswiftc -warnings-as-errors` for the packages in CI).
- CI runs `swift test --sanitize=thread` and `--sanitize=address` as separate jobs.
- The shared scheme enables Main Thread Checker and Thread Performance Checker for Run and Test.
- Logging uses `os.Logger` (subsystem is the bundle id, category per area, e.g. `queue`). Don't put file names or
  paths in log lines that persist.
