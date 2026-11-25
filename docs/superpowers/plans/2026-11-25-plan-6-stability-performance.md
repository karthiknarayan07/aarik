# Plan 6 — Stability and Performance Hardening

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the stability and performance gaps found by comparing the app with the owner's performance and stability guide (2026-11-25). Long batches survive sleep, heat, full disks and updates, and regressions are caught by CI.

**Source:** the owner's guide `macos-performance-stability.md` (AI-generated, links unverified). Only items that fit this app were adopted. Each was checked against the code on 2026-11-25:

- **Already met:**
  - Swift 6 strict concurrency, `@MainActor` UI, `@concurrent` engine
  - actors, cancellation, bounded `WorkSlots`, 10 Hz progress throttle
  - streaming VideoToolbox, atomic output, verify-before-Replace, persisted jobs
  - lazy grid, cached async thumbnails, `Logger`, Swift Testing, XCUITest (written)
- **Skipped:**
  - folder restructure (same responsibilities already exist in AppCore and MediaEngine)
  - hardened runtime (ad-hoc builds, ruled off in 1678d5b)
  - Core ML, Vision and PDF workers (out of scope)

## Global Constraints

- All Plan 2/3 constraints hold:
  - brand-neutral Swift
  - Swift 6 strict, zero warnings, `swift format lint --strict`
  - no third-party dependencies, offline
  - never delete or overwrite user files
- **No behaviour change without a test.** Every safety check has a unit test using a fake (disk space, thermal state, power assertion and clock behind small protocols).

## Phase A — low overlap, can run now

### Task A1: CI and build diagnostics
- `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in `Config/App.xcconfig`. In `Package.swift`, add `-warnings-as-errors` via `unsafeFlags` only for a CI configuration, or as a `swift build -Xswiftc -warnings-as-errors` step in CI.
- CI jobs: `swift test --sanitize=thread` and `swift test --sanitize=address`, as separate jobs.
- Shared scheme diagnostics: Main Thread Checker and Thread Performance Checker on for Run and Test.

### Task A2: Updates never interrupt work
- Sparkle `SPUUpdaterDelegate`: postpone install and relaunch while a job is running or the queue has waiting jobs (`updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`). Run the block once the queue is idle.
- Test with a fake queue state.

### Task A3: Engineering docs for agents
- `PERFORMANCE.md`: budgets, the measure–fix–measure loop, where signposts live, Release-only benchmarking.
- `STABILITY.md`: the file-safety rules (atomic output, verify-before-Replace, Trash only, no partial files, Work/ containment, Photos write limits), cancellation, sleep, thermal, disk space, updates.
- `AGENTS.md` (plus a `CLAUDE.md` that only points to it): build and test commands, constraints, and links to both docs. Keep each file short and true to the current code.

## Phase B — after Plan 3 Task 6 and Plan 4 Tasks 2–3 merge (they touch the runner and AppDelegate)

### Task B1: Disk-space preflight
- Before each job, and before an iCloud download, check `volumeAvailableCapacityForImportantUsage` on the output volume (and on the Work volume for Photos). It must cover the estimated output size, plus the input download size for Photos jobs, plus a 1 GB margin.
- Not enough space: the job fails with "Not enough free space on <volume> (needs about X, has Y)", nothing is written, and Retry works.

### Task B2: Sleep and thermal pressure
- While the queue runs, hold `ProcessInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason:)`, and release it when idle or paused. The display may sleep; the system may not.
- `ProcessInfo.thermalState`: at `.serious`, limit `WorkSlots` to 1; at `.critical`, pause after the current video and show "Paused while your Mac cools down". Resume automatically at `.fair` or better.
- Quitting while a job runs: confirm "Stop converting and quit?", and the job resumes on next launch (check the existing `applicationShouldTerminate`).

### Task B3: Signposts and regression tests
- `OSSignposter` intervals around read, transfer, encode, write, verify, download and save.
- Performance tests on a generated 4K fixture with `XCTClockMetric` and `XCTMemoryMetric`, plus `XCTApplicationLaunchMetric` in the UI test target. Fail on more than 20 % regression against stored baselines.
- Engine tests for corrupted input, variable frame rate, cancellation mid-encode and no space (with the fake). Add any of these that are missing.

## Release checklist additions (go into Plan 5 / docs/RELEASING.md)

- Release-build budgets on this Mac:
  - cold launch under 1 s
  - idle CPU under 1 %
  - idle memory under 150 MB
  - no hangs over 250 ms in the Hangs instrument during a 20-video batch
- A sustained 50-video batch: memory flat (no growth beyond 10 % after warm-up), originals intact on every failure.
- ASan and TSan CI green.

## Owner decisions (2026-11-25, via question tool)

- **Battery:** keep converting on battery, pause automatically at 20 % ("Paused: battery low"), resume when plugged in
  or above 25 %. Goes into Task B2 (IOPowerSources / `ProcessInfo` power state, behind a testable protocol).
- **Speed:** a Settings choice **Quiet / Balanced / Fastest**, default Balanced.
  - Quiet: one video at a time, background QoS.
  - Balanced: today's `WorkSlots`, half the cores, at least 2.
  - Fastest: all performance cores.
  Thermal rules still apply on top: `.serious` → 1, `.critical` → pause. Goes into Task B2.
- **Quit while converting:** ask "Stop converting and quit?"; the interrupted video and the rest of the queue resume on
  next launch. Task B2.
- **First release (v0.1.0):** everything planned — local files, Photos, quick runs (Dock, menu bar, Finder, Shortcuts)
  and this hardening — shipped once all plans are done and tested.
