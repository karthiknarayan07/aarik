# Continuation prompt: Plan 10 Phase 3 & polish (paste into a new agent)

You are continuing work on Aarik. Your working directory is `/Users/karthiknarayan/Developer/personal/aarik`, on the integration branch `plan-2-app-shell`, which tracks `origin/plan-2-app-shell`.

## Read first
- `AGENTS.md`, `STABILITY.md`, `PERFORMANCE.md`.
- Project memory in `~/.claude/projects/-Users-karthiknarayan-Developer-personal-aarik/memory/MEMORY.md`:
  - Max **3 parallel subagents** at a time (hard owner rule to preserve quota).
  - Subagents implement/fix/test in isolated workspaces (`share` / `worktree`); coordinator plans, briefs, merges, and pushes.
  - Native first on both platforms; brand-neutral code (never put `aarik` in Swift/plist/pbxproj/schemes).
  - Push `plan-2-app-shell` after every commit or merge. Never push to or merge into `main`.
  - Use the question tool (`ask_question` / `AskUserQuestion`) for owner questions.
- `docs/superpowers/plans/2026-11-26-plan-10-ios-and-convert.md` and `docs/superpowers/specs/2026-11-26-ios-and-convert-design.md`.
- `docs/adr/0005-compression-presets.md` and `docs/adr/0006-tool-core-services-and-scenes.md`.
- Ledger: `.superpowers/sdd/2026-11-26-plan-10-ios-and-convert/progress.md`.

## Where things stand (2026-11-26)
- **Merged and pushed** to `plan-2-app-shell`:
  - **Base**: Task 1 (iOS skeleton), Tasks 2+3 (`Apps/` layout, `App.xcworkspace`, `Packages/Core`, `Packages/Tools/Convert`, Convert rename), `scripts/verify.sh` + CI iOS job, Task 3b (`Tool`, `AppServices`, `ConvertModel`, `ConvertMacScene`, `ConvertIOSScene` stub, `MacShell`), Task 4 (`.iOS(.v26)`, `Platform` seams & iOS/fake adapters, Low Power Mode 1-slot rule, `#if os(macOS)` on `Photos.sqlite` fps).
  - Both `App` (macOS) and `App-iOS` build cleanly; `lint` and `hygiene` (`brand-neutral`, `stale paths`) pass.
- **In-flight or recently completed branches** (check `git log` on `plan-2-app-shell` first to see if Tasks 5, 6, 10 finished merging before quota paused):
  - `plan-10/task-5`: Convert video compression (`.compress(CompressPreset)`).
  - `plan-10/task-6`: iOS app shell & library (`NavigationSplitView`, Photos, Files -> Documents, Queue/Settings, Apple Intelligence).
  - `plan-10/task-10`: iOS Replace originals (`OriginalsDeleter` + `IOSPendingDeletionBar`).
- **Paused with WIP commits saved on branches** (no active worktrees; resume in fresh `share`/`worktree` checkouts of each branch, max 3 parallel):
  - `plan-10/task-7` (`ca2ecfd`): iOS background running (`BGContinuedProcessingTask`) & Live Activity — code written, needs `plan-2-app-shell` merge + verification (`AppCoreTests` + `App-iOS` build).
  - `plan-10/task-8` (`24c8ad1`): iOS Share extension & foreground App Intent (`StagedInputs`) — code + tests written, `lint`/`hygiene` passed, needs `plan-2-app-shell` merge + `AppCoreTests` + `App-iOS` build.
  - `plan-10/task-9` (`2a9e2e9`): iOS Home Screen widget & Control Center control (`WidgetSnapshotStore`, `SharedPauseFlagStore`) — code + `AppCoreTests` written, `App-iOS` build & `lint`/`hygiene` passed, needs `plan-2-app-shell` merge + post-format `AppCoreTests` verify.
  - `plan-10/task-12` (`38cb744`): Mac copy & polish pass (Title Case, Convert docs, Plan 9/6/3 parked Minors) — edits + `lint`/`hygiene` done, needs `plan-2-app-shell` merge (especially after Task 5 Compression merges!) + Mac build/tests.
- **Not started yet:**
  - **Test speed optimization**: `MediaEngineTests` on iOS Simulator hit Swift Testing's 300s timeout (software HEVC encoding in `FixtureFactory.makeClip` across 35+ clips). Fix by caching identical read-only fixtures in `FixtureFactory` (cloning into fresh temp dirs) and gating heavy multi-pass software-encode tests on Simulator via `EncoderEnvironment.isRepresentative` (keeping smoke encodes + all non-encoder tests active).
  - **Task 11**: iOS XCUITests (iPhone 17 Pro, iPad Pro 11-inch, iPhone Duo `AD2B36CE-232D-4240-9D6C-EFBA6367C0D3` by UDID), iOS performance tests/baseline, Instruments docs in `PERFORMANCE.md`, CI iOS UI tests.
  - **Base gate final run**: `scripts/verify.sh --repeat 2` (two consecutive green runs).
  - **Task 13**: Release gate checklist in `docs/RELEASING.md` for both apps.
- **Device signing note:**
  - `Karthik’s iPhone` (`00008120-00145D840AFBC01E`) uses Personal Team `95J795334T` (no App Group entitlement allowed on free teams). For local device preview installs, build with `DEVELOPMENT_TEAM=95J795334T CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_ENTITLEMENTS=""`. Also `Config/iOS.xcconfig` currently sets `CODE_SIGN_STYLE = Manual` / `DEVELOPMENT_TEAM =` *after* `#include? "Signing.local.xcconfig"`, so move `#include? "Signing.local.xcconfig"` below the defaults if fixing local override ergonomics.

## Next steps (strictly max 3 parallel subagents)
1. Check `git log -n 10 --oneline` on `plan-2-app-shell` and `git branch` for `plan-10/task-*` to see which of Tasks 5, 6, 10 still need finishing/merging; finish and merge them first (push after every merge).
2. Resume paused branches in batches of **at most 3**: e.g. Batch A = `plan-10/task-7`, `plan-10/task-8`, `plan-10/task-9` (each merges `plan-2-app-shell`, verifies fast targeted tests + `App-iOS` build + `lint`/`hygiene`, commits). Merge & push each.
3. Next batch (<=3): `plan-10/task-12` (merge `plan-2-app-shell` including Task 5 compression copy, verify Mac tests/build) + **Test speed optimization** (`FixtureFactory` cache + Simulator test fast-track). Merge & push.
4. Run **Task 11** (iOS UI tests & performance baseline) and **Task 13** (Release checklist in `docs/RELEASING.md`), then pass `scripts/verify.sh --repeat 2` twice green and push `plan-2-app-shell`.

## Rules that carry over
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Push `plan-2-app-shell` after every commit/merge. Never push to or merge into `main`.
- Never delete or overwrite user files or touch the owner's real Photos library.
