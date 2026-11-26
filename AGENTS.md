# AGENTS.md

Guide for coding agents working on this repository: a free, offline macOS app (Aarik) whose first tool shrinks
iPhone 4K video without losing metadata. Read `STABILITY.md` before touching anything that writes, moves or
deletes files, and `PERFORMANCE.md` before touching the engine, the queue or the UI update path.

## Layout

- `Packages/AppModules`: all logic, as SwiftPM targets (Swift 6, macOS 26).
  - `AppCore`: job model, `JobQueue` (actor), `JobStore`, `RelaunchGate`, output naming, metadata diff.
  - `MediaEngine`: inspection and the downscale engine (`VideoDownscaler`, `WorkSlots`, `AtomicOutput`).
  - `DownscaleVideo`: the tool: planner, presets, estimator, `DownscaleRunner` (verify, Replace, Trash).
  - `LocalLibrary`, `PhotosLibrary`: file and Photos browsing, `WorkFolder`, `PhotoInputFetcher`.
  - `AppUI`: shared view models. `MediaTestSupport` and `devtool`: fixtures and a command line for the engine.
- `App/`: the SwiftUI + AppKit shell (`App/Sources`), `App.xcodeproj`, Sparkle updater (`Updater.swift`).
- `Config/*.xcconfig`: build settings and brand values (`Brand.xcconfig`). `.github/workflows`: CI and release.
- `docs/`: ADRs, specs, plans (`docs/superpowers/plans`), `RELEASING.md`.

## Commands

Run from the repository root unless stated.

```sh
cd Packages/AppModules && swift build -Xswiftc -warnings-as-errors --build-tests
cd Packages/AppModules && swift test
cd Packages/AppModules && RUN_PERF_TESTS=1 swift test --filter PerformanceTests   # benchmark vs stored baseline
cd Packages/AppModules && swift test --sanitize=thread     # CI runs this and the address one as separate jobs
cd Packages/AppModules && swift test --sanitize=address
swift format lint --recursive --strict Packages/AppModules/Sources Packages/AppModules/Tests App/Sources
xcodebuild -project App/App.xcodeproj -scheme App -configuration Debug -derivedDataPath .build/xcode-p6 \
  -destination 'platform=macOS,arch=arm64' build    # also Release
scripts/run-app.sh                                   # build Debug and open it
```

Format with `swift format -i <files>`. Do not open or launch the app from an automated run unless asked.

## Verifying

`scripts/verify.sh` is the one command for the base gate and what CI calls. It runs, for every `Packages/**/Package.swift`,
`swift test`, the warnings-as-errors build and the tests on an iOS Simulator (found by UDID, iPhone 17 Pro preferred), then
`swift format lint --strict`, the Mac Debug and Release builds, the iOS app build and test, a brand-neutral check
(no product name in source, plists, projects or schemes under `Apps/` and `Packages/`) and a stale-path check. It prints a
pass/fail table and exits non-zero on any failure; missing projects or packages are failures, not skips.
`--only mac|ios|packages|lint|hygiene` runs a subset (CI uses `mac` and `ios`); `--repeat N` runs the whole suite N times
(the gate uses 2). Logs and derived data go to `.build/verify`.

## Constraints

- Swift 6, complete strict concurrency, **zero warnings** (warnings are errors in the app and in CI packages).
- `swift format lint --strict` must be clean over `Sources`, `Tests` and `App/Sources`.
- Brand-neutral code: no product name in identifiers, module names or bundle ids; the name lives in
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
