# Aarik on iOS, and the Convert tool — design

Status: draft for owner approval (2026-11-26). Extends `2026-11-25-aarik-design.md`; where they conflict, this one wins for platform layout, naming and iOS.

## Intent

Aarik becomes a family of small, offline, native media tools on **both macOS and iOS**. Today it is one Mac tool (shrink 4K iPhone video to 1080p with all metadata kept). The owner will add many tools later; some will run on the Mac only, some on iOS only, some on both — either identically or with platform checks. This change sets up that shape and ships the first tool on both platforms.

## Owner decisions (2026-11-26)

| Topic | Decision |
|---|---|
| Tool name | The Downscale/Video Shrinker tool is renamed **Convert** (Swift package `Convert`). |
| Convert scope for v0.1.0 | Today's 4K → 1080p **shrink**, plus **video compression** (same resolution, lower bitrate; presets Smaller / Balanced / Best Quality). Format change (MOV↔MP4, HEVC↔H.264) and photo conversion (HEIC/JPEG/PNG) come later and must plug in without restructuring. |
| iOS distribution | Dev builds only for now (Simulator and Xcode installs). App Store/TestFlight and the GPL-3.0 question are decided later. |
| iOS devices | iPhone, iPad and the foldable iPhone ("iPhone Duo") — one adaptive app. |
| Release | Both apps ship together as **v0.1.0**, each at full polish. |
| iOS entry points | In-app Photos browser and Files import, plus **Share sheet**, **Shortcuts and Siri**, **background processing with a Live Activity**, **Control Center control and Home Screen widget**. |
| Code sharing | **Shared Swift packages, two native app shells** (Mac Catalyst and a single multiplatform target were rejected as less native). |
| Apple Intelligence | On iOS too, same features, hidden when unavailable. |
| Native | Both apps must feel like Apple's own (see `native-first`): system controls, SF Symbols, semantic colours, Liquid Glass defaults, standard gestures, menus, shortcuts, VoiceOver, Dynamic Type; Title Case on controls, sentence case for descriptions. |
| Quality bar | Performance, resource use, profiling (signposts, Instruments), unit tests and UI tests polished on both. iOS verified in the Simulator for now. |

## Goals

- `Apps/macOS` and `Apps/iOS` app projects, one root `Aarik.xcworkspace`.
- Shared code in Swift packages outside `Apps/`; each tool its own package under `Packages/Tools/`.
- A tool declares which platforms it supports; the apps only show tools available on that platform.
- The Mac app keeps every v0.1.0 feature and behaviour already built (no regressions; its tests keep passing).
- The iOS app reaches feature parity where the platform allows: library browsing, queue, Replace originals (to Recently Deleted, after verification), Smart Picks, plain-words search, "Why?", speed/battery/thermal rules.

## Non-goals

- No App Store/TestFlight submission, no licence change.
- No sync between devices; no network use (the app stays offline; Sparkle is Mac-only).
- No tool switcher/Home cards yet (one tool still; ADR 0004 boundary stays "not a plugin system").
- No format-change or photo-conversion jobs in v0.1.0.
- No Mac Catalyst, no shared app target.

## Anti-goals (a failure even if it works)

- Either app feels like a port of the other (iPad UI on the Mac, Mac sidebars crammed onto iPhone).
- iOS conversion drains battery, gets the app killed in the background, or heats the phone without the pressure rules.
- Any path that deletes or overwrites a user's original before the copy is verified; any test touching the real Photos library.
- Shared packages gain `#if os` sprawl instead of clean platform seams.

## Constraints

- Swift 6 strict concurrency, macOS 26 and **iOS 26** minimum, Apple Silicon Macs; iOS device builds arm64.
- Existing safety rules carry over unchanged (atomic output, verify then Replace, Trash/Recently Deleted only, never write to the owner's Photos library without go-ahead and only on test assets).
- Brand only in `Config/Brand.xcconfig` (shared by both apps) and docs.
- Three in-flight Mac branches touch `App/`; the folder move and rename happen **after** they merge (sequencing, below).

## Approaches considered

1. **Shared packages, two native shells — chosen.** Engine, libraries, Assistant, view models and cross-platform views in packages; thin per-platform app projects own lifecycle, windows/scenes, menus, extensions. Most native on both; cost is two shells.
2. One multiplatform app target — rejected: the Mac's AppKit-owned window, status item, Services and Sparkle fight a shared lifecycle; `#if` everywhere in the app layer.
3. Mac Catalyst — rejected: the Mac app would stop feeling like a Mac app.

## Layout

```
Aarik.xcworkspace
Apps/
  macOS/   Aarik.xcodeproj   Sources/ (AppKit shell: AppDelegate, MainWindow, MenuFixups,
                             status item, Services, Sparkle, Settings scene), UITests/
  iOS/     Aarik.xcodeproj   Sources/ (SwiftUI App, scenes, BG task, Live Activity host)
                             ShareExtension/  Widgets/ (widget + Control + Live Activity UI)
                             UITests/
Config/    Brand.xcconfig, macOS.xcconfig, iOS.xcconfig
Packages/
  AarikKit/            one package, platform-neutral where possible
    AarikCore          (today AppCore: jobs, queue, settings, ToolModule, pressure policy)
    MediaEngine        (unchanged; AVFoundation/VideoToolbox, both platforms)
    LocalLibrary       (files; iOS via document picker / security-scoped URLs)
    PhotosLibrary      (PhotoKit; Mac Photos.sqlite fps path stays Mac-only)
    Assistant          (Foundation Models; both)
    SharedUI           (today AppUI: cross-platform views, rows, inspector, badges)
    AppState           (today App/Sources/AppModel*: the observable model, moved out of the app)
    Platform           (seams: power/thermal source, trash/recently-deleted, open-in, reveal)
  Tools/
    Convert/           Convert (jobs: shrink, compress; ConvertModule: ToolModule)
                       ConvertUI (tool views; platform pieces behind seams)
  (QuickRunService stays Mac-only inside the macOS shell or AarikKit behind os check)
```

Exact target names are the builder's call within this shape; the rule is: **platform-neutral by default, platform code behind a protocol seam in `Platform`, and `#if os` only at the seam implementations and the app shells.**

## Tool platform model

- `ToolModule` gains `static var platforms: ToolPlatforms` (OptionSet: `.macOS`, `.iOS`).
- Builders that differ by platform are protocol requirements with default implementations; a tool supplies platform variants only where it must.
- Each app's registry lists the tools it links and filters by `platforms`; a tool not built for a platform is simply not linked there (compile-time), and `platforms` keeps the UI honest at runtime.
- Convert: `[.macOS, .iOS]`.

## Convert in v0.1.0

- Job kinds: `.shrink` (today's behaviour, 4K→1080p, Dolby Vision route per ADR 0001) and `.compress(preset)`: keep resolution and frame rate, re-encode HEVC at a lower target bitrate. Presets **Smaller / Balanced / Best Quality** (exact bitrate ratios are the builder's call, recorded in an ADR, validated by the existing quality checks). All metadata kept exactly as shrink does.
- The job model is open for new kinds (format change, photo conversion) without changing the queue, persistence or UI shell.
- User-facing copy says "Convert" for the tool; actions stay plain ("Shrink to 1080p", "Compress…"). Existing Shortcuts intent `ShrinkVideosIntent` keeps working; a compress parameter is added.

## iOS app

- **Navigation:** `NavigationSplitView` (sidebar on iPad and the unfolded Duo, stack on iPhone and the folded Duo), adapting live to size-class and posture changes without losing selection.
- **Inputs:** Photos library browser (PhotoKit, limited-access aware); Files import via document picker. Size/resolution/duration from `PHAsset` without downloading; fps shown only once known (locally available or after download) — never download originals just to browse.
- **Running:** conversions start in the foreground and continue in the background through iOS 26 `BGContinuedProcessingTask`, with system progress UI; a **Live Activity** (Lock Screen and Dynamic Island) shows the queue. Downloads from iCloud one at a time (as on Mac).
- **Pressure:** same rules — battery pause at 20 %, resume when charging or above 25 %; thermal `.serious` → 1 slot, `.critical` → pause; **Low Power Mode → 1 slot**; speed setting Quiet/Balanced/Fastest.
- **Replace originals:** copy saved to Photos, verified, then the original goes to Recently Deleted through the system confirmation — same checks as Mac (`OriginalsDeleter`).
- **Share extension:** accepts videos from Photos/Files, hands them to the app's queue through the App Group (staged like the Mac intent staging; only staged copies are ever removed).
- **Shortcuts/Siri:** the shared App Intent.
- **Widget + Control:** Home Screen widget (space saved, queue count) and a Control Center control (open queue / pause-resume). Data shared via App Group.
- **Settings:** in-app Settings screen (iOS convention), same options minus Mac-only ones (menu bar, Services, updates).
- **Apple Intelligence:** same three features (plain-words search, "Why?", Smart Picks), availability re-checked on foreground.

## Mac app

Moves to `Apps/macOS`, consumes the renamed packages; behaviour unchanged. Mac-only pieces stay in the shell: AppKit window ownership, MenuFixups, status item and popover, Services, Finder Quick Action wiring, Sparkle, logout/quit policy.

## Quality

- Unit tests stay in the packages and run for both platforms (`swift test` on Mac; `xcodebuild test` on an iOS Simulator destination for the package schemes).
- UI tests: XCUITest for iOS on iPhone, iPad and iPhone Duo simulators (folded/half-open/open postures), light/dark, Dynamic Type sizes, VoiceOver labels. Mac UI tests stay blocked on automation approval.
- Performance: signposts shared; iOS performance tests (launch, conversion throughput, memory peak, energy) with a baseline like the Mac's; Instruments templates documented in `PERFORMANCE.md`.
- CI builds both apps and runs package tests on both destinations.

## Sequencing

1. Now (parallel with the in-flight Mac branches): this design, the plan, and iOS-only work that does not touch `App/` (iOS shell skeleton, extensions, `Platform` seams as new files).
2. After the three Mac branches merge: one restructure branch — move `App/` → `Apps/macOS`, split packages into `Packages/AarikKit` + `Packages/Tools/Convert`, rename Downscale/VideoShrinker → Convert, move `AppModel` into a package. Mac tests must pass unchanged.
3. Then in parallel: iOS feature tasks; Convert compression; Mac polish (Plan 9 Task 4 copy pass, which now also renames copy to "Convert").
4. Joint release v0.1.0.

## Settled after the builder check

Owner's answer:
- **iOS "done":** everything built and tested in the Simulator, with thermal, Low Power Mode, battery and background-task signals faked through `Platform` seams. Before tagging v0.1.0, the owner runs a short real-iPhone checklist (free or paid Apple ID) covering background continuation, Live Activity, pressure rules and energy. That checklist is part of the release gate.

Designer's calls (owner may correct):
- **Package graph, no cycles:** `AarikKit` holds only tool-agnostic code: queue, jobs protocol, settings, pressure policy, `ToolModule`, `LanguageModelClient`, availability and deadline, shared views, and `Platform` seams. Everything Convert-specific moves into `Packages/Tools/Convert`: the shrink/compress model extensions now in `AppModel+ShrinkVideos` and `AppModel+SmartPicks`, plus `QueryTranslator`, `OutcomeExplainer`, `SmartPicks` and the engine runners. The app shells compose the generic `AppState` with each tool's model via `ToolModule`. Dependencies point one way: Apps → Tools → AarikKit.
- **Extensions never convert.** iOS runs long work only in the app process, under `BGContinuedProcessingTask` started from a user action. The share extension stages the files into the App Group's Staging folder and offers "Open Aarik". The App Intent stages its inputs and opens the app (foreground mode); the app starts the run on arrival. The Control and the widget open the app or toggle pause through the App Group, and never start encoding out of process. Staging rules carry over from the Mac: only staged copies are removed, symlinks are never followed.
- **Killed or expired mid-job:** the partial output is discarded (atomic output already guarantees no half-file is ever visible), the job goes back to queued, and it restarts from the beginning on the next launch or the next continued-processing grant. The original is never touched. The UI test kills the app mid-run and checks this.
- **Replace originals on iOS:** this is never done in the background. Saved copies and pending originals accumulate, the same as on the Mac with `PendingDeletions`. When the app is in the foreground, a bar offers "Move N Originals to Recently Deleted…". That is one system confirmation per batch, and every entry is re-checked at delete time by the same `OriginalsDeleter` rules. The copy keeps exactly what the Mac copy keeps (ADR 0002); albums and favourites follow the Mac behaviour.
- **Sequencing detail:** step 1 adds only new files (iOS app project, extensions, new `Platform` seam files). Edits that make the shared packages iOS-ready (`.iOS(.v26)`, the AppKit seams) wait for step 2, because in-flight branches still touch the packages.
- **Rename and persistence:** module, type and user-facing names change. Persisted identifiers stay the same so no migration is needed: UserDefaults keys, the job-store file names and paths, Application Support folders, the App Intent type identifier and the Mac bundle ID. Tests keep their assertions and only update imports and type names.
- **Signing:** the iOS bundle ID is derived from `Brand.xcconfig` (Mac ID + `.ios`, extensions as sub-IDs), and the App Group is `group.<Mac bundle ID>`. Both are set as xcconfig variables so the owner can change them in one place. Simulator builds need no team; device builds use whatever team the owner sets in an untracked `Config/Signing.local.xcconfig`.

## Left to the builder

Exact target/file names within the layout; compression bitrate ratios (ADR); widget/Live Activity visual design within native defaults; how much of `SharedUI` is reused vs platform views (prefer reuse when it is idiomatic on both).
