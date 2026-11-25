# Plan 2 — App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable native Mac app: hybrid sidebar, Local Files grid of videos with size/badges, "Could free about X GB" header with High/Balanced/Smaller presets and per-clip estimates, inspector with metadata summary, a persistent serial queue with Activity lists (Queue / Completed / Kept As Is / Failed), Settings, and safe output (partial file → exclusive rename; Replace = verified copy then original to Trash).

**Architecture:** New package targets `AppUI` (shared SwiftUI components), `LocalLibrary` (user-added files/folders, scan, thumbnails, grouping, filters), `DownscaleVideo` (feature: presets, estimates, planner, runner, inspector section) on top of `AppCore` (now also: `Tool` contract, job model, `JobQueue` actor, persistence) and `MediaEngine`. A thin Xcode app target (`App/`) composes them; the brand lives only in `Config/Brand.xcconfig`.

**Tech Stack:** Swift 6.4, SwiftUI (`NavigationSplitView`, `.inspector`, `LazyVGrid`, `.quickLookPreview`), `@Observable`, AVFoundation (`AVAssetImageGenerator`), Swift Testing, Xcode 27 project with folder-synchronized groups, xcconfig.

**Spec:** `docs/superpowers/specs/2026-11-25-aarik-design.md` (§7.1, §7.1a, §8.2, §8.4, §8.5, §8.6, §9, §10a). Competitor notes: `docs/references/competitors.md`.

## Global Constraints

- macOS 26 minimum; **arm64 only** (`ARCHS = arm64` in the app's xcconfig).
- Swift 6 language mode, complete strict concurrency, zero warnings; `swift format lint` clean.
- **Brand-neutral code (§7.1a):** no "aarik" in any Swift file, target, module, type or identifier. Product name / display name / bundle ID prefix only in `Config/Brand.xcconfig` (`APP_DISPLAY_NAME = aarik`, `APP_BUNDLE_ID_PREFIX = io.github.karthiknarayan07`, `APP_PRODUCT_NAME = aarik`); UI text reads the name from `Bundle.main` (`CFBundleDisplayName`).
- No third-party dependencies (Sparkle comes in Plan 5). Fully offline: no networking APIs.
- Never modify a source file; never overwrite or delete a file the app did not create, except Replace, which moves the original to the **Trash** (never deletes) only after a verified output exists.
- UI rules (§9): system controls/colors, SF Symbols, sentence case, no emoji, light + dark, VoiceOver labels on every control, full keyboard use (⌘O add files, ⌘⏎ add selection to queue, Space preview, ⌘. pause queue).
- Inspiration from KeepFeather's *layout* only; no copying of its name, icon, copy text or styling.

## Review Focus

1. **App quits / crashes mid-job:** on next launch the job is back in the queue as *queued*, no stray partial file under a final name, and the user's original untouched. → Task 1 (partial files) + Task 4 (queue recovery).
2. **Same file added twice / two files that would get the same output name** (`IMG_1 (1080p).mov` exists): never overwrite; counter suffix. → Task 5.
3. **Source deleted, moved or on an ejected drive after it was added:** grid shows it unavailable; a queued job fails with a clear reason, Retry works when it's back. → Task 3 + Task 5.
4. **Folder with thousands of files:** scan is incremental and cancellable, UI stays responsive (no inventory of every file on the main actor). → Task 3.
5. **Clip that wouldn't save ≥10% or is already ≤ preset size:** goes to Kept As Is with the reason, never re-encoded, never upscaled. → Task 5.

---

## File Structure

```
Config/
  Brand.xcconfig                 brand: display name, product name, bundle id prefix
  App.xcconfig                   #include "Brand.xcconfig"; arm64, deployment 26.0, Swift 6, Info.plist keys
App/
  App.xcodeproj/                 hand-authored, objectVersion 77, folder-synchronized group for App/Sources
  Sources/
    MainApp.swift                @main, WindowGroup + Settings scenes, menu commands
    RootView.swift               NavigationSplitView: Sidebar | content | inspector
    AppModel.swift               @Observable composition root: LocalLibrary, JobQueue, ToolRegistry, selection
    ToolRegistry.swift           the ONE list of tools
  Resources/Assets.xcassets      placeholder AppIcon + AccentColor
Packages/AppModules/Sources/
  AppCore/Tools/Tool.swift                  ToolDescriptor, ToolCategory, Tool protocol
  AppCore/Jobs/Job.swift                    Job, JobState, JobOutcome
  AppCore/Jobs/JobQueue.swift               actor: serial run, pause/resume, persistence, recovery
  AppCore/Jobs/JobStore.swift               JSON persistence in Application Support
  AppCore/Output/OutputNamer.swift          "<name> (<label>).<ext>" + counter, never existing
  MediaEngine/Downscale/AtomicOutput.swift  partial path + renamex_np(RENAME_EXCL)
  LocalLibrary/LibraryItem.swift            id, bookmark, url, size, duration, dims, fps, date, badges, availability
  LocalLibrary/LocalLibrary.swift           @Observable (MainActor) facade: add files/folders, scan, group, filter, sort
  LocalLibrary/LibraryScanner.swift         background, cancellable, incremental scan
  LocalLibrary/BookmarkStore.swift          security-scoped bookmarks persistence
  LocalLibrary/ThumbnailCache.swift         AVAssetImageGenerator + memory/disk cache
  AppUI/…                                   SidebarList, MediaGrid, MediaTile, SavingsHeader, PresetPicker,
                                            EmptyState, ActivityList, MetadataSummary, ByteFormat
  DownscaleVideo/Preset.swift               Preset {high, balanced, smaller}, bitrate table
  DownscaleVideo/Estimator.swift            estimate(bytes) per preset, % saved
  DownscaleVideo/DownscalePlanner.swift     item + preset → JobPlan or KeptAsIs(reason); predicted report
  DownscaleVideo/DownscaleRunner.swift      runs a plan: downscale → verify → name/replace
  DownscaleVideo/DownscaleTool.swift        Tool conformance + inspector section view
  Tests/AppCoreTests/{JobQueueTests,OutputNamerTests}.swift
  Tests/LocalLibraryTests/LocalLibraryTests.swift
  Tests/DownscaleVideoTests/{PresetTests,EstimatorTests,PlannerTests,RunnerTests}.swift
  Tests/MediaEngineTests/AtomicOutputTests.swift
scripts/run-app.sh                          xcodebuild build + open the built .app
```

Package dependency rule: `DownscaleVideo` → `AppUI`, `MediaEngine`, `AppCore` (features never import `LocalLibrary`; they receive `URL`s + `MetadataInventory`). `LocalLibrary` → `MediaEngine` → `AppCore`; `AppUI` → `AppCore`. The app target imports everything.

---

### Task 1: Atomic output in the engine (spec final-review Important 8)

**Files:** Create `MediaEngine/Downscale/AtomicOutput.swift`; Modify `VideoDownscaler.swift`, `DownscaleSpec.swift`; Test `MediaEngineTests/AtomicOutputTests.swift`, existing `VideoDownscalerTests.swift`.

**Interfaces:**
- Produces: `DownscaleSpec.targetShortSide: Int?` — `nil` = keep source resolution (High preset); `sourceAlreadySmall` is thrown only when a non-nil target ≥ source short side. Existing default stays `1080`.
- Produces: internal `enum AtomicOutput { static func partialURL(for final: URL) -> URL; static func commit(partial: URL, to final: URL) throws }` — partial = same directory, name `.<final name>.partial-<UUID>`; commit = `renamex_np(partial, final, RENAME_EXCL)`; `EEXIST` → `DownscaleError.outputExists` (partial removed).
- The downscaler writes to the partial, copies file attributes onto it, then commits. On any failure/cancel it removes only the partial. The final path is touched only by the exclusive rename.

- [ ] **Step 1: Failing tests:** `commitRefusesExistingFinal` (final exists → `outputExists`, final bytes unchanged, partial removed); `downscaleWritesNoFinalUntilDone` (seam `beforeStartWriting` asserts the final path does not exist and a hidden partial does); `keepSourceResolution` (HLG 1280×720 fixture, `targetShortSide: nil` → output 1280×720, no throw); update `keepsOutputCreatedByOthersDuringRun` expectation: the foreign file at the *final* path survives and the run throws `outputExists` at commit.
- [ ] **Step 2:** `swift test --filter "AtomicOutputTests|VideoDownscalerTests"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same filter → PASS; full `swift test` → PASS, 0 warnings.
- [ ] **Step 5: Commit** — `feat(engine): write to a partial file and commit with an exclusive rename; allow keeping resolution`.

---

### Task 2: Xcode app target, brand config, empty shell

**Files:** Create `Config/*.xcconfig`, `App/App.xcodeproj` (hand-authored `project.pbxproj`, objectVersion 77, one macOS app target named `App`, `PBXFileSystemSynchronizedRootGroup` for `App/Sources` and `App/Resources`, local package reference to `../Packages/AppModules` linking `AppCore`, `AppUI`), `App/Sources/{MainApp,RootView,AppModel,ToolRegistry}.swift`, `scripts/run-app.sh`; Modify `Package.swift` (add `AppUI`, `LocalLibrary`, `DownscaleVideo` library targets + test targets; placeholders allowed in this task).

**Interfaces:**
- `Config/App.xcconfig`: `#include "Brand.xcconfig"`, `PRODUCT_NAME = $(APP_PRODUCT_NAME)`, `PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID_PREFIX).app`, `INFOPLIST_KEY_CFBundleDisplayName = $(APP_DISPLAY_NAME)`, `GENERATE_INFOPLIST_FILE = YES`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `ARCHS = arm64`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_IDENTITY = -` (ad-hoc), `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.photography`.
- `RootView`: `NavigationSplitView` with sidebar sections exactly: **Library** (Overview — placeholder "Coming with Photos", Videos — placeholder, Local Files), **Media types** (hidden until Task 3 provides counts), **Tools** (from `ToolRegistry`), **Activity** (Queue, Completed, Kept As Is, Failed). Content area shows an `EmptyState` per destination. Inspector toggle in toolbar (`.inspector(isPresented:)`).
- `scripts/run-app.sh`: `xcodebuild -project App/App.xcodeproj -scheme App -configuration Debug -derivedDataPath .build/xcode build` then `open` the built app.

- [ ] **Step 1:** Author the files. Brand name appears only in `Brand.xcconfig`.
- [ ] **Step 2:** `xcodebuild … build` → BUILD SUCCEEDED, 0 warnings. If the hand-authored project cannot be made to build, STOP and report BLOCKED with the exact error (do not install XcodeGen or other tools).
- [ ] **Step 3:** `scripts/run-app.sh` launches; window shows the four sidebar sections; quit cleanly. `git grep -i aarik -- App Packages` → only `Config/Brand.xcconfig` matches (it's outside both, so: no matches).
- [ ] **Step 4: Commit** — `feat(app): Xcode app target, brand config, hybrid sidebar shell`.

---

### Task 3: LocalLibrary — add, scan, thumbnails, group, filter

**Files:** `LocalLibrary/*`, `Tests/LocalLibraryTests/LocalLibraryTests.swift`.

**Interfaces:**
- `public struct LibraryItem: Identifiable, Sendable, Hashable { id: UUID; url: URL; byteSize: Int64; duration: Double; pixelSize: CGSize (display orientation); frameRate: Double; captureDate: Date?; badges: Set<MediaBadge>; isAvailable: Bool }`
- `public enum MediaBadge: String, Sendable, CaseIterable { dolbyVision, hdr, k4 = "4K", cinematic, sloMo, spatial, edited, sdr }` — derived from the inventory: DV from `hdr.dolbyVision`, HDR from HLG/PQ transfer, 4K if short side ≥ 2160, cinematic from a `track.*.kind` auxiliary video or `timed.*cinematic-video*`, slo-mo if fps ≥ 100, spatial from `hdr.stereo`, edited from a sibling `.aae`.
- `@MainActor @Observable public final class LocalLibrary { items: [LibraryItem]; isScanning: Bool; func add(_ urls: [URL]) (files or folders; folders scanned recursively for movie UTTypes); func remove(_ ids: Set<UUID>); func refreshAvailability(); groups(by: Grouping, sort: Sort, filter: MediaBadge?) -> [ItemGroup]; badgeCounts: [MediaBadge: Int]; totalBytes }`. `Grouping { year, month, none }`, `Sort { biggestFirst, newestFirst }`.
- Scanning runs off the main actor (`LibraryScanner` actor), yields items incrementally (batches of ≤ 50), is cancellable; uses `MediaInspector` per file (Review Focus 4).
- `BookmarkStore` persists security-scoped bookmarks (Application Support/`<bundle id>`/library.json); restored on launch; missing files → `isAvailable = false` (Review Focus 3).
- `ThumbnailCache.thumbnail(for: URL, maxPixel: 320) async -> CGImage?` (AVAssetImageGenerator, `appliesPreferredTrackTransform`, memory cache by URL+mtime).

- [ ] **Step 1: Failing tests:** `addFolderFindsOnlyMovies` (folder with 2 fixtures + a .txt → 2 items); `badgesFromInventory` (HLG fixture → `.dolbyVision`, `.hdr`; SDR 720p → `.sdr` only); `groupsByMonthBiggestFirst`; `missingFileBecomesUnavailable` (delete file → `refreshAvailability` → `isAvailable == false`); `bookmarksRoundTrip` (new `LocalLibrary` with same store restores items); `scanIsIncrementalAndCancellable` (100 tiny fixtures; cancel after first batch → fewer than 100 items, no crash).
- [ ] **Step 2–4:** RED → implement → GREEN; full suite 0 warnings.
- [ ] **Step 5: Commit** — `feat(library): local files library with scan, badges, grouping and bookmarks`.

---

### Task 4: AppCore — Tool contract, jobs, persistent serial queue

**Files:** `AppCore/Tools/Tool.swift`, `AppCore/Jobs/*`, `AppCore/Output/OutputNamer.swift`, tests.

**Interfaces:**
- `public struct ToolDescriptor: Sendable, Hashable { id: String; name: String; symbol: String; category: ToolCategory }`, `public enum ToolCategory { video, image, pdf, documents }`, `public protocol Tool: Sendable { static var descriptor: ToolDescriptor { get } }` (views are attached in the feature module; AppCore stays UI-free).
- `public struct Job: Codable, Sendable, Identifiable { id: UUID; toolID: String; source: URL; sourceBookmark: Data; settings: Data (tool-encoded); state: JobState; createdAt: Date }`; `public enum JobState: Codable, Sendable, Equatable { queued, running(progress: Double), completed(JobOutcome), keptAsIs(reason: String), failed(reason: String) }`; `public struct JobOutcome: Codable, Sendable, Equatable { output: URL; bytesBefore: Int64; bytesAfter: Int64; report: MetadataReport; replacedOriginal: Bool }`.
- `public protocol JobRunner: Sendable { func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState }` (returns `.completed` or `.keptAsIs`; throws → `.failed(reason)`).
- `public actor JobQueue { init(store: JobStore, runners: [String: any JobRunner]); func enqueue(_ jobs: [Job]); func pause(); func resume(); func retry(_ id: UUID); func remove(_ id: UUID); var jobs: [Job]; func updates() -> AsyncStream<[Job]> }` — one job at a time; `pause` lets the current job finish; on init, any persisted `.running` job is reset to `.queued` (Review Focus 1); persists after every state change.
- `public enum OutputNamer { static func url(for source: URL, label: String, in directory: URL) -> URL }` → `<stem> (<label>).<ext>`, then `<stem> (<label>) 2.<ext>`, … — first non-existing (Review Focus 2).

- [ ] **Step 1: Failing tests:** `runsSeriallyInOrder` (fake runner records start/end; no overlap); `pauseFinishesCurrent`; `failureBecomesFailedWithReason` and `retryRequeues`; `runningJobRecoveredAsQueued` (persist a `.running` job, new queue → `.queued`); `namerSkipsExisting` (create `a (1080p).mov` → returns `a (1080p) 2.mov`).
- [ ] **Step 2–4:** RED → implement → GREEN.
- [ ] **Step 5: Commit** — `feat(core): tool contract, persistent serial job queue, output namer`.

---

### Task 5: DownscaleVideo — presets, estimates, planner, runner

**Files:** `DownscaleVideo/{Preset,Estimator,DownscalePlanner,DownscaleRunner}.swift`, tests.

**Interfaces:**
- `public enum Preset: String, Codable, CaseIterable, Sendable { high, balanced, smaller }` with `func spec(for inventory: MetadataInventory, byteSize: Int64) -> DownscaleSpec`:
  - target short side: high → `nil` (keep); balanced, smaller → `1080`.
  - bitrate (spec §8.2): **high** = 50% of the source video bitrate (from `byteSize × 8 / duration`, minus audio), floor = balanced bitrate at the source resolution; **balanced** = `0.145 bits × outputWidth × outputHeight × min(fps, 60)` (1920×1080×30 → ≈ 9.0 Mbps); **smaller** = 60% of balanced. Clamp every result to ≥ 2 Mbps. Record the table in the code doc comment.
- `public enum Estimator { static func estimatedBytes(inventory: MetadataInventory, preset: Preset) -> Int64 }` = video bitrate × duration / 8 + audio bytes (source audio size kept as-is: use source total bytes − source video bytes estimate, floor 0) + 1%.
- `public enum PlanDecision: Sendable, Equatable { convert(DownscaleSpec, estimatedBytes: Int64, predicted: MetadataReport), keptAsIs(reason: String) }`; `public enum DownscalePlanner { static func decide(source: URL, inventory: MetadataInventory, byteSize: Int64, preset: Preset) -> PlanDecision }` — keptAsIs if estimated saving < 10% ("Would save less than 10%") or the preset would not shrink resolution and the source bitrate is already ≤ preset bitrate ("Already small"); spatial → keptAsIs("Spatial video isn't supported yet — it would lose one eye"). `predicted` = source inventory with `video.dimensions`/`hdr.dolbyVision` level as changed and auxiliary tracks (`track.*.kind` with `auxv`) as lost.
- `public struct DownscaleRunner: JobRunner` — settings = `{ preset, saveTo: .nextToOriginal | .folder(bookmark) | .replace }`; runs `VideoDownscaler` into the chosen directory via `OutputNamer` (label = "1080p" or "High" for keep-resolution); then `MetadataDiff.report(source, output)`; any lost item not in `predicted.lost` → still `.completed` but the report is stored (UI shows "Completed with warnings"). `.replace`: only if output verified (lost ⊆ predicted.lost) → `FileManager.trashItem(at: source)` then rename output to the source's name if free; otherwise keep output name. Unavailable source → throws "Original file is missing or the drive isn't connected" (Review Focus 3).

- [ ] **Step 1: Failing tests:** `presetBitratesScaleWithPixelRate` (1080p30 balanced in 8–10 Mbps; 4K keep high > balanced 1080p); `estimateWithinRange` (synthetic 4K HLG fixture: estimate within ±35% of an actual balanced run); `smallSourceIsKeptAsIs` (720p SDR + balanced → keptAsIs "Already small"); `spatialIsKeptAsIs` (inventory with `hdr.stereo`); `cinematicPredictsAuxLoss` (inventory with `track.1.kind = video/auxv`... → predicted.lost contains it); `runnerNextToOriginalNamesAndReports` (fixture → `x (1080p).mov` beside it, outcome bytes set, lost ⊆ predicted); `replaceTrashesOriginalOnlyAfterVerify` (source moved to Trash — assert source path gone and output at original name); `missingSourceFails`.
- [ ] **Step 2–4:** RED → implement → GREEN.
- [ ] **Step 5: Commit** — `feat(downscale): presets, estimates, planner and runner`.

---

### Task 6: Local Files screen — grid, header, inspector

**Files:** `AppUI/{MediaGrid,MediaTile,SavingsHeader,PresetPicker,EmptyState,MetadataSummary,ByteFormat}.swift`, `DownscaleVideo/DownscaleTool.swift` (inspector section), `App/Sources/{RootView,AppModel}.swift`.

**Interfaces / behavior (spec §9):**
- Toolbar: Years/Months/All segmented, sort menu (Biggest first default), search field, inspector toggle, **Add Files…** (⌘O, `fileImporter` allowing folders + movies, multiple).
- Header: "Could free about **X**" (sum over shown items of `byteSize − estimate` for items that wouldn't be Kept As Is), preset picker (High/Balanced/Smaller, persisted), bar now → after, one-line trust note "Nothing changes until you add to the queue".
- Grid: `LazyVGrid` adaptive tiles (min 150pt), month section headers "August 2026 · 9 videos", tile = thumbnail (aspect-fill, rounded 6), top-left badges (max 3), bottom-right size label; unavailable items dimmed with an exclamation badge; multi-select (⌘/⇧ click), Space → `.quickLookPreview`, arrow keys move selection.
- Media types section in the sidebar shows `badgeCounts` (non-empty only); selecting one filters the grid.
- Inspector (selection of 1): thumbnail, name, date · resolution · fps · duration, badges, preset rows "Original / High / Balanced / Smaller" with ≈size and −% (green), selected preset marked; **Advanced** disclosure (resolution 720/1080/1440/keep, bitrate field, frame rate) — stored per job; **MetadataSummary** = predicted kept count + changes + lost (orange) from `DownscalePlanner`; Save to (next to original / folder… / replace original), button **Add to Queue · <Preset>** (⌘⏎). Multi-selection: totals + same button "Add N to Queue". No selection: SF Symbol + "Select videos to see what converting them would save."
- Empty Local Files: SF Symbol, "Add videos from Finder", the three trust lines, buttons **Add Files…**; drag-and-drop of files/folders onto the window adds them.

- [ ] **Step 1:** Implement; keep views small (≤ ~150 lines each), logic in testable models (`AppModel` methods `couldFreeBytes(for:)`, `addSelectionToQueue()`).
- [ ] **Step 2:** Unit tests for the model logic in `Tests/DownscaleVideoTests` or a new `AppUITests` package test target (`couldFreeExcludesKeptAsIs`, `addSelectionCreatesOneJobPerItemWithPreset`).
- [ ] **Step 3:** `xcodebuild` build 0 warnings; run the app, add `Fixtures/iphone/` (if present) or generated fixtures, screenshot the window (light + dark) and attach paths in the report.
- [ ] **Step 4: Commit** — `feat(app): local files grid, savings header, presets and inspector`.

---

### Task 7: Activity screens, queue wiring, Settings, menus

**Files:** `AppUI/ActivityList.swift`, `App/Sources/*`.

**Behavior:**
- Queue: rows with thumbnail, name, preset, progress bar, state; toolbar Pause/Resume (⌘.), remove queued item; queue auto-starts when items are added (setting, default on).
- Completed: before → after, "Saved X (−Y%)", report badge **Verified** / **Completed with warnings** (click → report popover: kept / changed / lost), Show in Finder. Header total saved.
- Kept As Is: reason column. Failed: reason + **Retry** and **Retry All**.
- Sidebar Activity rows show counts; a running job shows a small progress ring on "Queue".
- Notifications: post a user notification when the queue finishes while the app is not frontmost (request authorization on first enqueue).
- Settings (`Settings` scene, tabs General / Output): default preset; default save-to (next to original / folder… ); auto-start queue; *Keep a copy of originals* (toggle + folder; stored now, used by Replace in Task 5 runner when on: copy original to the folder via `OutputNamer` before trashing; verify sizes match).
- Menu commands: File → Add Files… (⌘O); Queue → Add to Queue (⌘⏎), Pause/Resume (⌘.).
- Replace confirmation: first Replace in a session shows an alert: "The original goes to the Trash after the smaller copy is verified." [Cancel] [Replace].

- [ ] **Step 1:** Implement; tests for model logic (`activityCounts`, `retryAllRequeuesFailed`, `keepOriginalsCopiesBeforeTrash` in `DownscaleVideoTests` against the runner).
- [ ] **Step 2:** Build 0 warnings; run the app end-to-end on 2 fixtures (one converts, one Kept As Is) — screenshots of Queue running, Completed, Kept As Is.
- [ ] **Step 3: Commit** — `feat(app): activity lists, queue controls, settings and notifications`.

---

### Task 8: H.264 compatible output (Advanced)

**Files:** `MediaEngine/Downscale/{DownscaleSpec,HEVCEncoder→VideoEncoder,FrameScaler}.swift`, tests; inspector Advanced gets Format.

**Interfaces:** `DownscaleSpec.codec: VideoCodec = .hevcKeepHDR` with `.h264Compatible`; H.264: 8-bit, BT.709, High profile; HDR sources are tone-mapped to SDR (VTPixelTransferSession with destination BT.709 color properties, or Core Image `CIToneMapHeadroom` if transfer session can't tone map — builder chooses, documents why); Dolby Vision insertion `None`; predicted report marks `hdr.*`, `video.transferFunction`, `video.colorPrimaries`, `video.matrix`, `video.bitDepth`, `video.codec` as changed and `hdr.dolbyVision` as lost (expected, shown in orange before queueing).

- [ ] **Step 1: Failing tests:** `h264FromHLGIsSDR` (output codec `avc1`, transfer 709, bitDepth 8, no `hdr.dolbyVision`); `plannerPredictsHDRLossForH264`.
- [ ] **Step 2–4:** RED → implement → GREEN; full suite 0 warnings.
- [ ] **Step 5: Commit** — `feat(engine): H.264 compatible output with HDR to SDR tone mapping`.
