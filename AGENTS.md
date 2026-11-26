# AGENTS.md

Guide for coding agents working on this repository: a free, offline macOS app (Aarik) whose first tool shrinks
iPhone 4K video without losing metadata. Read `STABILITY.md` before touching anything that writes, moves or
deletes files, and `PERFORMANCE.md` before touching the engine, the queue or the UI update path. Scrolling, large libraries and anything only a phone shows: `docs/testing/performance-and-device.md`.

## Layout

Dependencies point one way: Apps -> Tools -> Core. Core never imports a tool, a tool never imports an app.

- `Packages/Core` (package `Core`, Swift 6, macOS 26): everything that is not specific to one tool.
  - `AppCore`: job model, `JobQueue` (actor), `JobStore`, `RelaunchGate`, output naming, metadata diff, pressure
    policy, `ToolModule`, `ToolPlatforms` and `ToolRegistry`.
  - `MediaEngine`: inspection and the downscale engine (`VideoDownscaler`, `WorkSlots`, `AtomicOutput`).
  - `LocalLibrary`, `PhotosLibrary`: file and Photos browsing, `WorkFolder`, `PhotoInputFetcher`.
  - `Assistant`: the generic `LanguageModelClient`, availability and `Deadline`.
  - `AppUI`: shared view models. `MediaTestSupport` and `devtool`: fixtures and a command line for the engine.
- `Packages/Tools/Convert` (package `Convert`): the first tool.
  - `Convert`: planner, presets, estimator, `ConvertRunner` (verify, Replace, Trash), and the assistant features that
    read its results (`QueryTranslator`, `OutcomeExplainer`, smart picks).
  - `ConvertUI`: its SwiftUI inspector views. `QuickRunService`: Shortcuts, Services, menu bar and Dock entry points
    (only the Mac app links it).
- `Apps/macOS`: the SwiftUI + AppKit shell (`Apps/macOS/Sources`, `App.xcodeproj`, Sparkle updater `Updater.swift`).
  `Apps/iOS`: the iOS app (`App.xcodeproj`, scheme `App-iOS`, with the share and widget extensions, `UnitTests` and `UITests`).
  `App.xcworkspace` at the root holds both projects and the packages; the Mac scheme is `App`.
- `Config/*.xcconfig` (`macOS.xcconfig`, `iOS.xcconfig`, `Brand.xcconfig`): build settings and brand values.
  `.github/workflows`: CI and release.
- `docs/`: ADRs, specs, plans (`docs/superpowers/plans`), `RELEASING.md`.

## Commands

Run from the repository root unless stated.

```sh
cd Packages/Core && swift build -Xswiftc -warnings-as-errors --build-tests
cd Packages/Core && swift test
cd Packages/Tools/Convert && swift build -Xswiftc -warnings-as-errors --build-tests
cd Packages/Tools/Convert && swift test
cd Packages/Core && RUN_PERF_TESTS=1 swift test --filter PerformanceTests   # benchmark vs stored baseline
cd Packages/Core && swift test --sanitize=thread     # CI runs this and the address one as separate jobs
cd Packages/Core && swift test --sanitize=address    # same for Packages/Tools/Convert
swift format lint --recursive --strict Packages/Core/Sources Packages/Core/Tests \
  Packages/Tools/Convert/Sources Packages/Tools/Convert/Tests Apps/macOS/Sources Apps/iOS
xcodebuild -workspace App.xcworkspace -scheme App -configuration Debug -derivedDataPath .build/xcode-p6 \
  -destination 'platform=macOS,arch=arm64' build    # also Release
xcodebuild -workspace App.xcworkspace -scheme App-iOS -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
scripts/run-app.sh                                   # build Debug and open it
scripts/ios-ui-tests.sh [--udid UDID] [--perf]       # iOS unit tests + XCUITests on one Simulator (generated fixtures)
scripts/device-perf.sh [--udid UDID] [--trace]       # Photos scroll test on a connected iPhone (real library, read only)
```

Format with `swift format -i <files>`. Do not open or launch the app from an automated run unless asked.

## Verifying

`scripts/verify.sh` is the one command for the base gate and what CI calls. It runs, for every `Packages/**/Package.swift`,
`swift test`, the warnings-as-errors build and the tests on an iOS Simulator (found by UDID, iPhone 17 Pro preferred), then
`swift format lint --strict`, the Mac Debug and Release builds, the iOS app build and test, a brand-neutral check
(no product name in source, plists, projects or schemes under `Apps/` and `Packages/`), a stale-path check, and two
text checks (`scripts/text-lint.py`): no `...` inside a Swift string literal (use the ellipsis character), and no tool name
("Convert", "Shrink", "compress") in the app-level screens listed in `scripts/app-level-screens.txt`, with the legitimate
exceptions in `scripts/app-level-text-allowlist.txt`. It prints a
pass/fail table and exits non-zero on any failure; missing projects or packages are failures, not skips.
`--only mac|ios|packages|lint|hygiene|text` runs a subset (CI uses `mac` and `ios`); `--repeat N` runs the whole suite N times
(the gate uses 2). Logs and derived data go to `.build/verify`.

## Constraints

- Swift 6, complete strict concurrency, **zero warnings** (warnings are errors in the app and in CI packages).
- `swift format lint --strict` must be clean over every package's `Sources` and `Tests`, `Apps/macOS/Sources` and `Apps/iOS`.
- Brand-neutral code: no product name in identifiers, module names, project or target names, or bundle ids; the name lives in
  `Config/Brand.xcconfig` and in prose only.
- No third-party dependencies except Sparkle. Offline: no analytics, no network except the update check.
- Never delete or overwrite user files; originals go to the Trash only after verification (see `STABILITY.md`).
- No behaviour change without a test. Put decisions in small testable types behind protocols or closures
  (see `RelaunchGate`, the `Trasher` and `exclusiveRename` seams) instead of testing through the UI.
- UI state is `@MainActor`; engine work is `@concurrent` or in actors. Don't block the main actor.
- Photos: the user's assets are read-only inputs. New assets are added only through `PhotoSaver` (one
  `performChanges`, verified after saving, removed again on mismatch); an original is deleted only as a
  user-confirmed action through the system's delete confirmation. Tests use `FakePhotoStore`, never the real library.
- No secrets in the repository. The update signing key never goes in `Config`; see `docs/RELEASING.md`.
- Update `CHANGELOG.md` for user-visible changes. Commits: small, one concern each, imperative subject.

## Status of the hardening work

`docs/superpowers/plans/2026-11-25-plan-6-stability-performance.md`. Done: sanitizer CI jobs, warnings as errors,
scheme diagnostics, update relaunch held while work runs, disk-space preflight, signposts and performance tests,
sleep prevention, thermal and battery pauses, the speed setting and the quit confirmation (`AppCore/Pressure`), and
the engine stall watchdog.
