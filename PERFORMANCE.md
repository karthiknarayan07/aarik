# Performance

What the app does today to stay fast, the budgets it is held to, and how to measure. Items marked "planned" are
not in the code yet.

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

These are checked by hand before a release (the checklist is to be added to `docs/RELEASING.md`). Regressions in
engine time and memory are caught by the performance tests below.

## Measure, fix, measure

1. State the symptom with a number ("launch 1.8 s", "RAM 600 MB after 30 videos").
2. Measure a **Release** build only. Debug is `-Onone` and tells you nothing about speed:
   `xcodebuild -workspace App.xcworkspace -scheme App -configuration Release -derivedDataPath .build/xcode-p6 build`.
3. Profile with Instruments (Time Profiler, Allocations, Hangs, Points of Interest) or time the engine without the
   UI: `cd Packages/Core && swift run -c release devtool downscale <in> <out>` (`devtool fixture <path>`
   makes a test clip; `devtool inspect <file>` prints metadata).
4. Change one thing, measure again with the same input, and record both numbers in the commit message.
5. Keep the fix only if the number improved and the tests still pass. Never trade file safety (STABILITY.md) for
   speed: no skipping verification, no in-place writes.

## Signposts

`OSSignposter` intervals, all through one signposter (`Signposts` in `AppCore/Safety/Signposts.swift`: the app's
subsystem, category Points of Interest), so they show in Instruments' Points of Interest and Time Profiler lanes.
The names are stable; `PipelineStage` is the list and a test pins it. Adding a stage means adding it here.

| Interval | Where | Covers |
| --- | --- | --- |
| `read` | `DownscaleJob.run` | one video sample from `AVAssetReader` |
| `transfer` | `DownscaleJob.run` | scaling one frame (`VTPixelTransferSession`) |
| `encode` | `DownscaleJob.submitPending` | submitting one frame to `VTCompressionSession` |
| `write` | `DownscaleJob.appendEncoded`, `run` | appending one encoded sample; finishing the file |
| `verify` | `DownscaleRunner.convert` | reading the output back, and comparing it with the source |
| `download` | `PhotosDownscaleRunner.fetchInput` | getting a Photos video onto this Mac (iCloud download, or copy, and an edit's render) |
| `save` | `PhotosDownscaleRunner.saveToPhotos` | adding the new video to Photos and checking it |

`read`, `transfer`, `encode` and `write` are per frame or sample, so a clip shows thousands of short intervals;
`verify`, `download` and `save` are one per job. Beyond these, only `os.Logger` is used (`queue` category in
`JobQueue`).

## Performance tests

- `Packages/Core/Tests/PerformanceTests` (XCTest, because `measure` and the metrics are XCTest's):
  - `DownscalePerformanceTests` downscales a **generated** 3840x2160 HLG clip (two seconds, with audio; never personal
    media) five times under `measure(metrics: [XCTClockMetric(), XCTMemoryMetric()])`, and compares the fastest time
    and the median rise in physical memory with the stored baseline. More than 20 % worse fails; memory also gets
    10 MB of room, since it is sampled every 10 ms on a machine doing other things.
  - It runs only with `RUN_PERF_TESTS=1` (it skips itself otherwise): it takes about 5 to 15 s, but timings need a
    quiet machine and would flake in a shared everyday run.
  - **Baselines are a JSON file** (`PerformanceTests/Baselines/baselines.json`), keyed by hardware model and core
    count. SwiftPM can't store XCTest baselines (`swift test` neither reads nor writes `xcbaseline` files, which
    belong to an Xcode project), so the 20 % rule is applied in the test. A machine with no entry measures, prints
    the numbers and passes. `BaselineGuardTests` covers the rule itself and runs every time.
  - **Release build.** The committed baseline was recorded from a Release build, and the benchmark runs the same way:
    `RUN_PERF_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter PerformanceTests` (`-enable-testing`
    because the other test targets use `@testable`; with the filter only this target runs). Record or update the
    baseline on a quiet Mac by adding `RECORD_PERF_BASELINE=1`, and commit the file. A plain Debug `swift test` run
    also works but is slower to build and its numbers are not comparable.
  - **Who enforces it.** The 20 % rule is enforced locally, on the release Mac, as a step of the release checklist
    (`docs/RELEASING.md`). The CI job `performance-report` only runs the benchmark in Release, prints the numbers
    and uploads them as a JSON artifact (`PERF_REPORT_PATH`); hosted runners are too varied to hold a baseline.
- Launch time (Mac): `Apps/macOS/UITests/LaunchPerformanceTests.swift` (`XCTApplicationLaunchMetric`, Xcode baselines; set "Max %
  Regression" to 20, Xcode's default is 10) belongs in the `AppUITests` target of the `ui-tests` branch; the target is
  not on this branch, so it doesn't build yet. Running UI tests needs automation permission.

## iOS performance

- **Tests.** `Apps/iOS/UITests/PerformanceTests.swift` (XCTest UI tests, so `measure`, `XCTApplicationLaunchMetric`,
  `XCTClockMetric`, `XCTMemoryMetric` and `XCTCPUMetric` apply):
  - `testLaunch`: launch to the first screen, five iterations; the pass/fail time is the fastest.
  - `testConversionThroughput`: one generated 4K HLG clip from Add to Queue until it shows in Completed, three
    iterations, each from a fresh launch and library.
  - Peak memory and CPU come from the app itself: a Debug-only sampler (`-uiTestingProbe <file>`, `PerformanceProbe`)
    writes the process's peak physical footprint and CPU seconds every 100 ms, because a UI test process can't read them
    from the app. The metrics above still run, so the result bundle shows them too.
- **Baseline JSON.** `Apps/iOS/UITests/Baselines/baselines.json`, the same shape and the same 20 % rule as the Mac's
  (memory gets 10 MB and CPU 0.5 s of room). It is keyed by simulated device and host core count
  (`iPhone18,3/10`); a machine with no entry measures, prints and passes. Record one on a quiet Mac, then commit the file:
  `scripts/ios-ui-tests.sh --record-perf`. Check against it: `scripts/ios-ui-tests.sh --perf`. The tests skip unless
  `RUN_PERF_TESTS=1`. `BaselineGuardTests` covers the rule and runs with every UI test run.
- **What the numbers mean.** The Simulator uses a software encoder on the Mac's CPU, so they catch regressions between
  builds; they say nothing about an iPhone's speed or heat. Real-device numbers come from Instruments (below) on the
  owner's iPhone.
- **CI** builds the iOS app and runs the UI tests (not the performance tests) on one iPhone Simulator.

### Instruments on an iPhone

Profile a **Release** build on a real device (Product > Profile, or `xcodebuild ... -configuration Release` and Xcode's
Instruments with the device selected). Use a short generated or test clip, never personal media. Record, change one
thing, record again with the same clip.

| Template | Use it to | What to look for |
| --- | --- | --- |
| Time Profiler | See where CPU goes during a conversion and while browsing | The main thread should be nearly idle during a run; engine work sits in `VideoDownscaler`/VideoToolbox frames on the encoder and blocking-read threads, not `body` of a SwiftUI view. Filter by the app's subsystem signposts (`read`, `transfer`, `encode`, `write`, `verify`). |
| Allocations | Memory growth and leaks across a batch | Run 20 videos back to back: Mark Generation after each. Persistent growth per video is a leak; the share extension and the app must never hold a whole video in memory (steady state under about 150 MB; the extension's cap is much lower). |
| Energy Log (Energy Efficiency) | Battery cost of a run and of idle | Idle must be near zero and the work must stop when the queue empties. Check CPU, thermal state and "Overhead" lanes during a 10-minute batch; compare Low Power Mode on and off. |
| Hangs (and Animation Hitches) | Main-thread stalls | No hang over 250 ms while browsing the Photos grid, rotating, and during a run; the grid scrolls without hitches. |

Also useful: Points of Interest (the same `Signposts` intervals as the Mac) and the Xcode Energy and Memory gauges for a
quick look. Record any real-device numbers you act on in the commit message, as for the Mac.

## Rules of thumb for changes

- No work on the main actor except UI state; engine work stays `@concurrent` or in an actor.
- Publish less, not more: coalesce updates the way `JobQueue` coalesces progress.
- Stream or chunk anything proportional to video size; never load a file into `Data`.
