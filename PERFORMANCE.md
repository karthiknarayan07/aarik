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
- **One job at a time in the queue.** `JobQueue` (actor) runs jobs in order and persists after each state change.
- **Progress throttle.** Progress alone is published to the UI at most every 100 ms (`progressInterval`); state
  changes go out immediately.
- **UI.** The grid is lazy, thumbnails come from an async cache (`ThumbnailCache`, `ThumbnailSource`), and
  Photos metadata is read without downloading anything (about 4 ms per asset, see ADR 0002).
- **Photos input** is fetched into `Work/<job id>/` just before its job and removed right after; at most one such
  input exists at a time.

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
   `xcodebuild -project App/App.xcodeproj -scheme App -configuration Release -derivedDataPath .build/xcode-p6 build`.
3. Profile with Instruments (Time Profiler, Allocations, Hangs, Points of Interest) or time the engine without the
   UI: `cd Packages/AppModules && swift run -c release devtool downscale <in> <out>` (`devtool fixture <path>`
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

- `Packages/AppModules/Tests/PerformanceTests` (XCTest, because `measure` and the metrics are XCTest's):
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
- Launch time: `App/UITests/LaunchPerformanceTests.swift` (`XCTApplicationLaunchMetric`, Xcode baselines; set "Max %
  Regression" to 20, Xcode's default is 10) belongs in the `AppUITests` target of the `ui-tests` branch; the target is
  not on this branch, so it doesn't build yet. Running UI tests needs automation permission.

## Rules of thumb for changes

- No work on the main actor except UI state; engine work stays `@concurrent` or in an actor.
- Publish less, not more: coalesce updates the way `JobQueue` coalesces progress.
- Stream or chunk anything proportional to video size; never load a file into `Data`.
