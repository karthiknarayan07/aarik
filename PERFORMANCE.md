# Performance

What the app does today to stay fast, the budgets it is held to, and how to measure. Items marked "planned" are
Plan 6 Phase B and not in the code yet (signposts and regression tests, B3).

## Design that already matters

- **Streaming encode.** `VideoDownscaler` reads samples with `AVAssetReader`, scales and encodes through
  VideoToolbox, and writes with `AVAssetWriter`; video is never held whole in memory. Audio, timed metadata and
  other tracks are passed through without re-encoding.
- **Bounded concurrency.** `WorkSlots` (an actor) admits half the cores, at least 2, concurrent downscales; waiters
  hold no thread. Blocking reads run on a `BlockingWorkExecutor` of their own, off the shared Swift pool, and
  `downscale` is `@concurrent` so a main-actor caller never blocks.
- **Speed setting and thermal rules.** Settings has Quiet, Balanced (default) and Fastest. `PressureState` turns
  the choice, the thermal state and the core counts into a limit, and the app applies it to `WorkSlots` at runtime
  (`DownscaleThrottle.apply`): Quiet is 1 with the encoder's blocking work at background priority; Balanced is half
  the cores, at least 2; Fastest is the performance cores (`hw.perflevel0.physicalcpu`), never fewer than Balanced and never more than the active cores (M3: 4 and 4, M4: 5 and 5, M4 Pro: 7 and 10). `.serious` heat makes it 1
  and `.critical` pauses the queue (STABILITY.md). Lowering the limit never stops a running downscale: it applies
  as they finish; raising it admits waiting ones at once. The same number is the queue's concurrency
  (`JobQueue.setConcurrency`, sent with the automatic hold): Quiet runs one job at a time, Balanced and Fastest run
  that many jobs at once. Lowering it never stops a running job; raising it starts waiting jobs at once.
- **Several jobs at once in the queue.** `JobQueue` (actor) starts queued jobs in order up to its concurrency (1
  until the app sets it), each in a task of its own, and persists after each state change. A finished job lets the
  next waiting one start. Pause, cancel (one job or all), quit and the automatic hold act on every running job.
  Progress from all running jobs shares the one throttle; the queue's progress is their mean.
- **One download at a time.** Whatever the concurrency, Photos jobs fetch one at a time (`DownloadGate` in
  `PhotosDownscaleRunner`, also for the backup's fetch of an original): the others show "Waiting for another
  download…" and can be cancelled while they wait. Converting and saving still overlap with another job's download.
- **Progress throttle.** Progress alone is published to the UI at most every 100 ms (`progressInterval`); state
  changes go out immediately.
- **UI.** The grid is lazy, thumbnails come from an async cache (`ThumbnailCache`, `ThumbnailSource`), and
  Photos metadata is read without downloading anything (about 4 ms per asset, see ADR 0002).
- **Photos input** is fetched into `Work/<job id>/` just before its job and removed right after; at most one fetch is
  under way at a time, but a fetched input stays until its own job ends, so up to the queue's concurrency of them
  can exist at once.

## Budgets (Release build, Apple silicon, this Mac)

| Budget | Target |
| --- | --- |
| Cold launch | under 1 s |
| Idle CPU (queue empty, window open) | under 1 % |
| Idle memory | under 150 MB |
| Main-thread hangs during a 20-video batch | none over 250 ms (Hangs instrument) |
| 50-video batch | memory flat: under 10 % growth after warm-up |

These are checked by hand before a release (the checklist is to be added to `docs/RELEASING.md`). Automated
regression tests with stored baselines are planned (B3).

## Measure, fix, measure

1. State the symptom with a number ("launch 1.8 s", "RAM 600 MB after 30 videos").
2. Measure a **Release** build only. Debug is `-Onone` and tells you nothing about speed:
   `xcodebuild -project App/App.xcodeproj -scheme App -configuration Release -derivedDataPath .build/xcode-p6 build`.
3. Profile with Instruments (Time Profiler, Allocations, Hangs, Points of Interest) or time the engine without the
   UI: `cd Packages/AppModules && swift run -c release devtool downscale <in> <out>` (`devtool fixture <path>`
   makes a test clip; `devtool inspect <file>` prints metadata).
4. Change one thing, measure again with the same input, and record both numbers in the commit message.
5. Keep the fix only if the number improved and the tests still pass. Never trade file safety (STABILITY.md) for
   speed: no skipping verification, no in-place writes.

## Signposts

None yet. `OSSignposter` intervals around read, transfer, encode, write, verify, download and save are planned
(B3). Only `os.Logger` exists today (`queue` category in `JobQueue`).

## Rules of thumb for changes

- No work on the main actor except UI state; engine work stays `@concurrent` or in an actor.
- Publish less, not more: coalesce updates the way `JobQueue` coalesces progress.
- Stream or chunk anything proportional to video size; never load a file into `Data`.
