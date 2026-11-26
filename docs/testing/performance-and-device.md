# Performance and real-device testing

How the Photos grid scroll problem got past the tests, how to run the scroll test, how to profile, and what counts as
passing. `PERFORMANCE.md` has the engine and queue budgets; this page is about scrolling and about what only a phone
shows.

## Why the simulator tests missed it

The first report came from an iPhone 14 Pro Max with a large real library ("scrolling the Photos grid lags and hangs").
Every test we had passed, because:

- **A small synthetic library.** The UI tests add three generated clips to the Simulator's Photos. A grid of three
  tiles never scrolls, never evicts a poster and never has a request nobody waits for.
- **A fast Mac CPU.** The Simulator runs the app on the Mac's cores, many times faster than a phone's, so work that costs
  a frame on a phone costs nothing there.
- **No scroll metrics.** The tests measured launch time and conversion throughput only. Nothing watched frame pacing.
- **No device runs.** The Simulator also has no display link, so `XCTHitchMetric` and the scroll signpost metrics report
  nothing there at all. Only a device produces hitch or frame-rate numbers.
- **A grid that XCUITest could not even scroll.** A simultaneous `DragGesture` for "swipe across tiles to select" sat on
  the whole grid while browsing. It took every touch from the scroll view: synthesized swipes did not move the grid, on
  the Simulator or on the iPhone. A test that had tried to scroll would have found that at once.

What was proven (each by a test or a measurement, not assumed):

| Suspect | Result |
| --- | --- |
| `photoSections` recomputed on every body pass | **Not the cause.** It was already cached in `LibraryBrowser` (`GridSectionsCacheTests` pins it: 1,000 reads and a preset or selection change rebuild nothing). |
| Scan progress invalidating the grid | **Not the cause.** The Photos list is assigned once per fetch; "Reading…" flips once. Library changes were another matter, see below. |
| Dead thumbnail requests | **Cause.** A tile that scrolled away did not cancel its request: the cache ran each one to the end in an unstructured task. A fling past 300 tiles ran all 300 (`THUMBNAIL dead requests that ran to the end: 300 of 300` before, 0 after, `ThumbnailCancellationTests`). |
| Gesture on the grid content | **Cause.** The sweep `DragGesture` was attached while browsing (see above). It now exists only while selecting. |
| PhotoKit work per tile | `PHAsset.fetchAssets` ran for every poster, on the default image manager, and the image was decoded on first draw on the main thread. Now: assets are kept from the listing, one `PHCachingImageManager`, and the poster is decoded off the main thread. |
| Library changes | Every `photoLibraryDidChange` (any asset, any sync) refetched and rebuilt every item on the main actor. Now: only a change to the video fetch result counts, refetches are limited to about four a second, and the rebuild and compare run off the main actor. |
| Tiles redrawing | `LibraryTile` is `Equatable` and the grids use `.equatable()`; a tile that scrolls back in reads its poster from memory (`ThumbnailCache.cachedImage`) instead of flashing a placeholder. |

## Running the scroll test

`PhotosScrollPerformanceTests` opens Browse > Convert > Photos, checks that the grid really moves, then flings it up and
down for `UI_SCROLL_SECONDS` (default 20) per iteration, three iterations, measuring
`XCTOSSignpostMetric.scrollDraggingMetric` and `scrollDecelerationMetric`, `XCTHitchMetric`, CPU and memory.

**Simulator** (a synthetic library of 2,500 videos with mixed sizes, shapes and badges, every ninth iCloud-only with no
local poster, each poster taking a few milliseconds like PhotoKit; Debug-only `-uiTestingFakePhotos 2500`):

```sh
scripts/ios-ui-tests.sh --udid <UDID> --perf --only PhotosScrollPerformanceTests
scripts/scroll-perf-report.sh .build/ios-ui/results/<UDID>.xcresult
scripts/verify.sh --perf          # the same, as one opt-in step of the gate
```

The Simulator gives CPU time and memory only (useful between builds, not as a verdict). It cannot give hitch numbers.

**Device** (the real library, read only: nothing is added, changed or converted; never run it with seeding):

```sh
scripts/device-perf.sh [--udid UDID] [--seconds 20] [--trace]
```

It signs with the Personal Team (`DEVELOPMENT_TEAM` to override), runs the test with `UI_FAKE_PHOTOS=0` and applies the
thresholds below. `--trace` also records a Time Profiler trace to `.build/device-perf/scroll.trace`. Photos access must
already be granted to the app on the phone. Run it on a quiet phone: plugged in or charged, Low Power Mode off, not hot.
Do not loop it; each run takes a few minutes and scrolls the owner's phone.

## Profiling

- **Instruments** on the phone: Time Profiler (main-thread hotspots; filter to the main thread, look for `ThumbnailCache`,
  `PHImageManager`, `LibraryTile`, layout), Animation Hitches (which frames, and whether the commit or the render was
  late), Hangs, and Allocations for posters (a 480 px poster is about 0.9 MB decoded, 300 are kept).
- **xctrace** from the command line:

```sh
xcrun xctrace record --template 'Time Profiler' --device <UDID> --attach <pid> --time-limit 30s --output scroll.trace
xcrun xctrace export --input scroll.trace --toc            # what tables the trace holds
xcrun xctrace export --input scroll.trace --xpath '/trace-toc/run/data/table[@schema="time-profile"]'
```

  Replace `--attach <pid>` with `--launch -- <app path>` to start the app under the profiler. Profile a Debug build only
  to find work that should not be there at all; judge speed on Release.
- In the result bundle, `xcrun xcresulttool get test-results metrics --path X.xcresult` lists every metric the test took.

## What passes

`scripts/scroll-perf-report.sh` applies these to a device run (the Simulator run only reports):

| Metric | Passes when |
| --- | --- |
| Hitch time ratio | under 5 ms/s (Apple calls under 5 "good") |
| Hitches per iteration | 10 or fewer |
| Frame rate | at least 55 fps; aim for a steady 120 on ProMotion |
| Peak memory | no growth across iterations beyond noise; the app stays well under the jetsam limit |

The synthetic-library gate on the Simulator cannot fail on hitches (it has none); a regression there shows as CPU time
growing by more than 20 % against the previous build, read by hand.

## Real-device checklist (before a release)

Run on a physical iPhone, Release or TestFlight-style build, with the owner's library or one like it:

- [ ] **Scrolling.** Fling Browse > Convert > Photos and Files up and down for 30 seconds. No stall when a fling starts,
  none when it stops, posters fill in without the tiles jumping, scrolling back shows posters at once.
- [ ] **Large library.** With more than 1,000 videos, opening Photos shows the grid within a few seconds and stays
  responsive while "Reading..." shows. Pull Photos into the background and back: no rebuild stall.
- [ ] **Library changes.** Take a photo (not a video) while the grid is open, or let iCloud sync: nothing flickers or hangs.
- [ ] **iCloud-only items.** Videos whose originals are in iCloud show a placeholder or their local poster, never start a
  download while browsing (Settings > Cellular and Wi-Fi traffic for the app stay at zero), and scrolling past hundreds of
  them stays smooth.
- [ ] **Low memory.** Scroll for a minute with several other apps open. Posters may reload, but the app is not killed and
  memory in Xcode's gauge does not climb. Trigger a memory warning from Xcode (Debug > Simulate Memory Warning) while
  scrolling: the grid keeps working.
- [ ] **Select mode.** Tap Select, then swipe sideways across tiles to select a run; a vertical drag still scrolls.
- [ ] Run `scripts/device-perf.sh` once and keep its report with the release notes.
