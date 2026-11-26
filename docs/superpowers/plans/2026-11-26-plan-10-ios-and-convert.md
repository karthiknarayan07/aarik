# Plan 10: iOS app, Apps/ layout and the Convert tool. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Aarik v0.1.0 as two native apps, macOS and iOS (iPhone, iPad, iPhone Duo), built from shared packages. The first tool is renamed **Convert** and gains video compression.

**Architecture:** Two thin native app shells under `Apps/` sit on Swift packages. Dependencies point one way: Apps → `Packages/Tools/Convert` → `Packages/AarikKit`. Platform differences live behind protocol seams; `#if os` appears only in seam implementations and the shells.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AppKit (Mac shell), UIKit only where SwiftUI lacks an API, AVFoundation, VideoToolbox, PhotoKit, FoundationModels, AppIntents, ActivityKit, WidgetKit, BackgroundTasks (`BGContinuedProcessingTask`), Swift Testing, XCUITest.

**Spec:** `docs/superpowers/specs/2026-11-26-ios-and-convert-design.md`. It extends `docs/superpowers/specs/2026-11-25-aarik-design.md`.

## Global Constraints

- Minimum macOS 26 and **iOS 26**. Swift 6 language mode, and `-warnings-as-errors` stays clean. `swift format lint --strict` stays clean.
- Dependency direction is Apps → Tools → AarikKit. AarikKit never imports a tool. A tool never imports an app.
- `ToolModule.platforms: ToolPlatforms` (OptionSet `.macOS`, `.iOS`). Convert is `[.macOS, .iOS]`.
- Persisted identifiers do not change: UserDefaults keys, job-store file names and paths, Application Support folders, the App Intent type identifier, and the Mac bundle ID. Renames touch code and copy only.
- Brand lives only in `Config/Brand.xcconfig`. The iOS bundle ID is `$(APP_BUNDLE_ID_PREFIX).aarik.ios` (or the Mac ID + `.ios`, whichever matches the Mac's derivation), extensions use sub-IDs, and the App Group is `group.<Mac bundle ID>`. Signing goes in the untracked `Config/Signing.local.xcconfig` (gitignored, with an optional `#include?`).
- Native first, on both platforms: system controls, SF Symbols, semantic colours, Liquid Glass defaults (never hand-applied glass), standard gestures, menus and shortcuts, context menus, Quick Look, Share, drag and drop, Undo, VoiceOver, Dynamic Type. Title Case for controls, sentence case for descriptions, an ellipsis on controls that open more UI.
- Safety:
  - Never delete or overwrite user files. Output is atomic.
  - Replace moves originals only to the Trash (Mac files) or Recently Deleted (Photos), only after `OriginalsDeleter` re-checks, and only in the foreground.
  - Tests never read the real Photos library.
  - Only staged copies are ever removed, and symlinks are never followed.
  - Personal media and `docs/references/KeepFeather/` are never committed.
- iOS extensions (Share, Widget, Control, Intent) never encode. They stage the input and open the app, or flip state through the App Group.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus

1. **A size class or posture change mid-run** (iPad split view, Duo folding or unfolding, iPhone rotation): selection, queue progress and any open sheet survive with no reload and no restarted job.
2. **The app killed or the background grant expiring mid-encode:** no partial file is visible, the job returns to queued and restarts, and the original is untouched.
3. **Photos access is limited or denied on iOS:** native states appear, nothing downloads to browse, and pending originals outside the limited set stay pending.
4. **The share extension receives a non-video, a huge file or many items:** it stays under the extension memory cap (it copies by streaming, never loads into memory), skips non-videos with a count, and staging never follows a symlink.
5. **The rename breaks an existing Mac user:** their saved queue, settings and a Shortcut built on `ShrinkVideosIntent` still work after updating.

---

## Phase 1: now, in parallel with the in-flight Mac branches (new files only)

### Task 1: iOS app skeleton and shared config

**Files:**
- Create: `Apps/iOS/Aarik.xcodeproj`. Targets: `Aarik` (app), `AarikShare` (share extension), `AarikWidgets` (widget + Control + Live Activity UI), `AarikUITests`.
- Create: `Apps/iOS/Sources/AarikApp.swift`, `Apps/iOS/Info.plist`, entitlements (App Group), and `Apps/iOS/Resources/` (asset catalog pointing at `Branding/`).
- Create: `Config/iOS.xcconfig` (includes `Brand.xcconfig` and an optional `Signing.local.xcconfig`).
- Modify: `.gitignore` (`Config/Signing.local.xcconfig`).

- [ ] Each target builds for the iOS 26 Simulator with placeholder SwiftUI views. There are no package dependencies yet.
- [ ] The UI test `testLaunchShowsRoot` launches the app on an iPhone Simulator and finds the root view by accessibility identifier.
- [ ] Run `xcodebuild -project Apps/iOS/Aarik.xcodeproj -scheme Aarik -destination 'platform=iOS Simulator,name=iPhone 17' build test`. Expected: it succeeds.
- [ ] Commit.

---

## Phase 2: restructure. It starts after `ui/shell-browser` and `plan-3/task-8` are merged, and runs serially.

### Task 2: move the Mac app to Apps/macOS and add the workspace

**Files:** `git mv App Apps/macOS` (project renamed to `Apps/macOS/Aarik.xcodeproj`), `Aarik.xcworkspace` at the root (both projects plus the packages), `Config/macOS.xcconfig` (the old `App.xcconfig`), paths in `scripts/`, `.github/workflows/*.yml`, `AGENTS.md`, `docs/RELEASING.md`, and the Sparkle and release scripts.

- [ ] The Mac Debug and Release builds succeed from the workspace, and `swift test` is unchanged and green.
- [ ] The CI workflow builds the Mac app from its new path.
- [ ] Use `git mv` so history follows the files. Commit.

### Task 3: split packages, rename to Convert, move AppModel out of the app

**Target layout:**
- `Packages/AarikKit/Package.swift` contains:
  - `AarikCore` (the old `AppCore`: queue, jobs protocol, settings, pressure policy, `ToolModule`, `ToolPlatforms`)
  - `MediaEngine`
  - `LocalLibrary`
  - `PhotosLibrary`
  - `Assistant` (the generic `LanguageModelClient`, availability and `Deadline` only)
  - `SharedUI` (the old `AppUI`)
  - `AppState` (the tool-agnostic part of `App/Sources/AppModel*`)
  - `MediaTestSupport`
  - `devtool`
- `Packages/Tools/Convert/Package.swift` contains:
  - `Convert` (the old `DownscaleVideo` plus the Convert-specific model extensions: the `AppModel+ShrinkVideos`, `+SmartPicks` and `+Originals` pieces that are tool-specific, and `QueryTranslator`, `OutcomeExplainer`, `SmartPicks`)
  - `ConvertUI` (tool views, the old `VideoShrinkerModule` renamed `ConvertModule`)
- `QuickRunService` stays Mac-only: it moves into the macOS shell, or stays a target that only the Mac links.

- [ ] Rename types and copy: Downscale/VideoShrinker become Convert. User-facing actions stay plain ("Shrink to 1080p").
- [ ] Follow Global Constraints on persisted identifiers. Add a test, `persistedIdentifiersUnchanged`, that pins the UserDefaults keys, job-store path and intent identifier to their pre-rename literal values.
- [ ] Add `ToolPlatforms`, plus `ToolModule.platforms` with Convert set to `[.macOS, .iOS]`. The Mac registry filters by `.macOS`; test it with a fake module whose platforms are `.iOS`.
- [ ] Every existing test still passes with only its imports and type names changed. Test count must be ≥ the count before the restructure; record both counts in the report.
- [ ] Commit the move separately from the rename (`git mv` first) so the diffs stay reviewable.

---

## Phase 3: in parallel after Task 3

### Task 4: make AarikKit and Convert iOS-ready

- [ ] Add `.iOS(.v26)` to both packages. Each piece of AppKit or IOKit code goes behind the existing seams (`ThermalSource`, `PowerSource`, `ActivityStarter` in `AarikCore/Pressure`) or a new seam in `AarikCore/Platform/`:
  - trash or recently-deleted
  - reveal and open-in
  - images (`PlatformImage` typealias)
  - the pasteboard and drag-out
- [ ] Give `PowerSource` a new `isLowPowerMode: Bool`.
- [ ] Add a pressure rule, Low Power Mode → 1 slot. Test it as `lowPowerModeLimitsToOneSlot`.
- [ ] Add iOS implementations: `UIDevice` battery monitoring, `ProcessInfo.thermalState` and `isLowPowerModeEnabled` with their notifications, and an iOS activity token (`beginActivity` is still correct).
- [ ] The Photos.sqlite fps path is `#if os(macOS)` only. On iOS, fps is `nil` until known; test it as `iosFpsUnknownUntilLocal` with a fake asset source.
- [ ] Both packages' tests run on an iOS Simulator destination with `xcodebuild test -scheme AarikKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'`, and the same for Convert. Add both to CI.

### Task 5: Convert video compression

- [ ] Add a job kind `.compress(CompressPreset)`, where `CompressPreset` is `.smaller`, `.balanced` or `.bestQuality`. Compression keeps resolution, frame rate, HDR and Dolby Vision handling, and all metadata exactly as shrink does.
- [ ] Choose the target bitrates as a ratio of the source and record them in **ADR 0005**. They are validated by the existing quality checks and by fixtures.
- [ ] Make the job kind extensible: adding a future kind must not change the queue, persistence or shell. Old saved jobs decode as `.shrink`; test it as `oldJobsDecodeAsShrink`.
- [ ] Mac UI: a "Compress…" action next to Shrink, with the presets in a native picker.
- [ ] Add a `mode` parameter to `ShrinkVideosIntent` (default Shrink, so existing Shortcuts are unchanged).
- [ ] Add a performance baseline entry for compression.

### Task 6: iOS app shell and library

This task depends on Task 4.

- [ ] The `Aarik` iOS app composes `AppState` and `ConvertModule` through an iOS tool registry filtered by `.iOS`.
- [ ] `NavigationSplitView` shows a sidebar on iPad and the unfolded Duo, and a stack on iPhone and the folded Duo. Selection persists through size-class and posture changes (Review Focus 1).
- [ ] The Photos browser uses PhotoKit, shows native limited and denied states, and never downloads originals to browse.
- [ ] Files import uses the document picker with security-scoped URLs.
- [ ] Outputs for Files inputs go to the app's Documents, which shows in Files as On My iPhone › Aarik. Replace is not offered for Files inputs on iOS in v0.1.0 (ruling: there is no safe system Trash for arbitrary file providers).
- [ ] Queue, Completed, inspector and Settings screens (with the Mac-only options removed) use `SharedUI` where it is idiomatic and native iOS views elsewhere.
- [ ] Apple Intelligence features: plain-words search tokens, Why? and Smart Picks. Availability is re-checked on `scenePhase == .active`.

### Task 7: iOS background running and Live Activity

This task depends on Task 6.

- [ ] Starting a run submits a `BGContinuedProcessingTaskRequest`, with its wildcard identifier in `BGTaskSchedulerPermittedIdentifiers`. The handler reports progress, honours expiration by cancelling cleanly, and re-queues the job (Review Focus 2). Test it with a fake scheduler seam, `expirationRequeuesAndDiscardsPartial`.
- [ ] A Live Activity in `AarikWidgets` shows the current item, progress and queue count on the Lock Screen and in the Dynamic Island. It is updated at most once a second, and ended on finish, cancel or pause.
- [ ] On launch, a job left `.running` is reset to `.queued` and its partial output removed. The existing Work sweep covers the removal.

### Task 8: iOS share extension and App Intent

This task depends on Task 6.

- [ ] `AarikShare` accepts `public.movie`. It stream-copies each item into the App Group `Staging/<uuid>/`, then shows a native confirmation with "Open Aarik". It stays under the extension memory cap (Review Focus 4). Tests: `stagingStreamsLargeFile`, `stagingSkipsNonVideos`, `stagingNeverFollowsSymlinks`.
- [ ] The app picks up staged items on activation. Both the intent and the share flow reuse `StagedInputs`, which moves to `AarikCore` with an App Group root on iOS.
- [ ] The shared App Intent runs in the foreground (opens the app). Its parameters match the Mac.

### Task 9: iOS widget and Control

This task depends on Task 6.

- [ ] A Home Screen widget, in small and medium sizes, shows space saved and the queue count, read from an App Group snapshot that the app writes on change.
- [ ] A Control Center control toggles pause and resume through an App Intent that flips a shared flag. The app observes the flag, and the control never encodes.
- [ ] Widget timelines reload when the app's snapshot changes, with no polling.

### Task 10: iOS Replace originals

This task depends on Task 6.

- [ ] A foreground-only bar reads "Move N Originals to Recently Deleted…" and triggers one system confirmation per batch, using the same `PendingDeletions` and `OriginalsDeleter` as the Mac (Review Focus 3). Tests reuse the Mac deleter tests on an iOS destination.

### Task 11: iOS UI tests, performance and profiling

This task runs after Tasks 6–10.

- [ ] Run XCUITests on iPhone 17, an iPad Pro (13-inch) and the iPhone Duo Simulator in folded, half-open and open postures; in light and dark; at Dynamic Type default and AX3. Cover:
  - browsing and queueing a fixture video. Load fixture media into the Simulator's Photos with `xcrun simctl addmedia`; the Simulator library is not the owner's library.
  - Files import
  - run to Completed
  - kill mid-run, relaunch, and check the job re-queues
  - Settings
  - share-extension hand-off (staged item picked up)
- [ ] Performance tests: launch, conversion throughput, peak memory and CPU, with a baseline JSON like the Mac's. Document the Instruments templates (Time Profiler, Allocations, Energy, Hangs) in `PERFORMANCE.md`.
- [ ] CI builds the iOS app and runs the iOS UI tests on one iPhone Simulator.

### Task 12: Mac copy and polish pass (Plan 9 Task 4, extended)

This task runs after Tasks 3 and 5.

- [ ] Plan 9 Task 4 as written (Title Case everywhere, N15), plus the "Convert" naming in copy, the README, CHANGELOG and screenshots list.
- [ ] Fold in the parked Minors from the Plan 9, Plan 6 and Plan 3 ledgers.

### Task 13: release gate for both apps

- [ ] Add a real-iPhone checklist to `docs/RELEASING.md`, run by the owner before tagging. It covers:
  - background continuation and expiry
  - the Live Activity
  - battery, thermal and Low Power Mode rules
  - Energy Log
  - share sheet, widget and Control
  - Replace to Recently Deleted on test assets only
- [ ] The v0.1.0 tag requires both apps green in CI and the checklist done.
