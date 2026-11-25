# aarik — Design

**Date:** 2026-11-25
**Status:** Draft for approval
**Scope of this doc:** the app foundation (architecture every future tool plugs into) and the first tool, **Downscale Video**.

---

## 1. Intent and why

aarik is a free, open-source, offline macOS toolbox in the spirit of iLovePDF: a set of focused tools that convert, shrink, and reshape everyday files — video, images, PDFs, documents — entirely on the user's Mac.

Why it exists (all of these, per the owner):

- **Own pain:** the owner wants a tool they actually use daily, starting with shrinking iPhone video.
- **Privacy / offline:** web tools make you upload your files. aarik never does.
- **Learning + portfolio:** this is the owner's first desktop app; the codebase should be something to be proud of.
- **Community:** it should be easy for outside contributors to add new tools.

**Success for the first public release:** the owner uses it daily to downscale iPhone footage — mainly **to free up Photos / iCloud storage** — and trusts it not to lose anything they care about.

**The distinctive promise:** *keep everything.* When aarik converts a file, every piece of metadata that can survive does survive, and anything that can't is named to the user before it happens and verified after.

## 2. Goals

1. Ship **Downscale Video** excellently for iPhone footage: 4K → 1080p (and other sizes) preserving Dolby Vision / HDR, camera and lens info, location, dates, audio (including spatial audio where possible), and Live Photo / Photos linkage.
2. Build an architecture where **each tool is a self-contained feature module**; adding a tool = add a folder + register it in one place.
3. Feel like a **real Mac app**: native sidebar window, native controls, keyboard-driven, light/dark, accessible. No "AI slop" UI.
4. Reach tools from **four entry points**: main window, Finder right-click, menu bar drop target, Shortcuts app.
5. Work with both **Finder files and the Photos library** as input and output.

## 3. Non-goals (for this release)

- Image, PDF, and Office tools (they come next, as separate feature modules; see §11).
- Windows / Linux. aarik is Mac-only, permanently.
- Intel Macs (see §5).
- Video editing beyond downscale / format / frame rate (no trimming, filters, color grading).
- Localization beyond English (structure strings for it, don't translate yet).
- Mac App Store distribution.

## 4. Anti-goals (would be a failure even if it "works")

- **Uploading or phoning home.** No telemetry, no analytics, no cloud. aarik's own network traffic is limited to the Sparkle update check (user can turn it off) and, later, the user-approved LibreOffice download. Asking Photos to fetch the user's own originals from their iCloud library is allowed (that is Photos talking to the user's iCloud, not aarik talking to anyone), with progress and cancel.
- **Silent metadata loss.** Losing something without telling the user first is a bug, not a trade-off.
- **Destroying originals.** Originals are never modified unless the user explicitly chooses Replace, and even then it's recoverable.
- **Generic / templated UI.** No gradient hero cards, emoji, glassmorphism beyond what macOS itself provides, marketing copy, or web-app-in-a-window feel.
- **Feature sprawl in the core.** If adding a tool requires edits in many places, the architecture has failed.

## 5. Constraints

| Constraint | Decision | Source |
|---|---|---|
| Platform | macOS only | Owner |
| Minimum OS | macOS 26 | Owner |
| CPU | Apple Silicon only (arm64) | *My call:* macOS 27 already drops Intel; Dolby Vision encoding and hardware HEVC quality are Apple Silicon features; halves the test matrix. |
| Toolchain | Xcode 27.2, Swift 6.4 (owner's machine) | Recon |
| Apple Developer account | **None** for now. Ship ad-hoc signed, un-notarized. Add signing later without code changes. | Owner |
| Distribution | GitHub Releases (DMG) + Sparkle 2 auto-updates (EdDSA-signed, free). No Homebrew (requires notarization), no App Store. | Owner + recon |
| License | GPL-3.0 | Owner |
| Third-party code | Minimal. Sparkle is the only expected runtime dependency; a Dolby Vision RPU library/tool (e.g. `dovi_tool`, MIT) only if the spike proves it necessary (§8.3a). No FFmpeg, no UI libraries. | My call |

**Known consequence of no signing:** first launch shows macOS's "can't verify" dialog; users must use System Settings → Privacy & Security → Open Anyway. The README and the download page must document this with screenshots. Privacy permissions (Photos) may need re-granting after updates because the code signature changes; the app should detect a lost permission and re-prompt gracefully.

## 6. Approaches considered

### 6.1 Platform
- **Mac-only native (chosen).** Apple's media stack is the only offline option that reliably preserves iPhone Dolby Vision through a re-encode; PDF/image frameworks are built in; smallest app; most native feel.
- Mac-first with later ports — rejected: no code would be shared anyway, so it only adds abstraction cost.
- Cross-platform (Tauri/Electron + FFmpeg) — rejected: weaker Dolby Vision handling contradicts the core promise; less native feel.

### 6.2 Codebase structure
- **A. Thin app shell + local Swift package `AppModules` with one module per feature (chosen).** Compiler-enforced boundaries; app, Finder extension, and Shortcuts share the same feature code; no extra tooling; tiny Xcode project means few merge conflicts.
- B. Tuist-generated workspace — rejected: strongest structure, but every contributor must learn a generator; overkill for one maintainer.
- C. Single target, folders by convention — rejected: boundaries erode; extensions can't cleanly reuse code.

### 6.3 Video engine
- **AVFoundation + VideoToolbox (chosen).** Hardware HEVC/H.264 encode, Dolby Vision support, native QuickTime metadata handling, PhotoKit interop.
- FFmpeg — rejected: large bundle, GPL/LGPL build complexity, poor Dolby Vision re-encode support.

### 6.4 Distribution
- **Unsigned now, sign later (chosen).** Free; same code; upgrade path is just CI configuration.
- Unsigned forever / account from day one — rejected by owner.

## 7. Architecture

### 7.1 Repository layout

```
<repo>/
├─ Config/Brand.xcconfig        # the ONLY place the product name / bundle ID live (see §7.1a)
├─ App/                         # macOS app target (thin)
│  ├─ MainApp.swift             # @main, scenes: main window, MenuBarExtra, Settings
│  ├─ ToolRegistry.swift        # the ONE place features are listed
│  └─ Resources/                # Assets, Info.plist, entitlements
├─ Extensions/
│  ├─ FinderAction/             # right-click "Downscale with <app name>" etc.
│  └─ (Intents live in features, surfaced via App Intents)
├─ Packages/AppModules/         # local Swift package
│  ├─ Package.swift
│  ├─ Sources/
│  │  ├─ AppCore/             # Tool contract, job queue, inputs/outputs, metadata model, verification
│  │  ├─ AppUI/               # shared SwiftUI components (drop zone, queue list, kept/lost badge, inspector)
│  │  ├─ MediaEngine/           # AVFoundation/VideoToolbox plumbing shared by video & image tools
│  │  ├─ PhotosBridge/          # PhotoKit import/export/replace
│  │  └─ Features/
│  │     └─ DownscaleVideo/     # settings, planner, runner, views, intents
│  └─ Tests/
│     ├─ AppCoreTests/
│     ├─ MediaEngineTests/
│     └─ DownscaleVideoTests/
├─ Fixtures/                    # small sample media (see §10)
├─ docs/
│  ├─ superpowers/specs/        # design docs
│  ├─ adr/                      # architecture decision records
│  └─ adding-a-tool.md          # contributor guide
├─ .github/workflows/           # build, test, release
├─ LICENSE                      # GPL-3.0
└─ README.md
```

Dependency rule (enforced by `Package.swift`): `Features/*` → `AppUI`, `MediaEngine`, `PhotosBridge` → `AppCore`. Features never import each other. The app and extensions import features only through `ToolRegistry`.

### 7.1a Brand-neutral code (owner decision, 2026-11-25)

"aarik" is a working brand; the final name may change. Code must never carry the brand:
- Packages, modules, targets, types, files, test identifiers and env vars use generic names (`AppModules`, `AppCore`, `AppUI`, `MediaEngine`, `devtool`, `com.example.fixture.*`, `REAL_CLIP_GATE`).
- The product name, display name, bundle ID prefix and app-group / extension IDs are defined once in `Config/Brand.xcconfig` (e.g. `APP_DISPLAY_NAME`, `APP_BUNDLE_ID_PREFIX`) and referenced everywhere else via build settings; user-facing strings that mention the name read it from the bundle (`CFBundleDisplayName`), never a literal.
- The brand may appear only in: `Config/Brand.xcconfig`, `README.md`, `docs/`, app icon / assets, and the GitHub repo name.
- Renaming the app = edit `Brand.xcconfig`, assets, README/docs (and optionally the repo); no Swift code changes.

### 7.2 The Tool contract (sketch — exact API is the builder's call)

Every feature module provides one type conforming to a `Tool` protocol in `AppCore`, describing:

- **Descriptor:** stable ID, display name, SF Symbol, sidebar category (Video / Image / PDF / Documents), accepted input types (`UTType`s).
- **Settings:** a `Codable`, `Sendable` value with defaults; persisted per tool.
- **Plan:** given inputs + settings, produce one job per input, each carrying a **MetadataReport** (kept / changed / lost) *before* anything runs.
- **Run:** execute a job with progress and cancellation, producing an output.
- **View:** the tool's settings UI, embedded in a standard tool screen that `AppUI` provides (drop zone, queue, report badges, inspector, Convert button) so every tool looks consistent.
- **Intents:** App Intents so the tool appears in Shortcuts and the Finder action.

`ToolRegistry` in the app lists the tools; the sidebar, menu bar drop target, Finder action, and Shortcuts are all generated from it. **Adding a tool = new folder under `Features/`, conform to `Tool`, add one line to `ToolRegistry`.**

### 7.3 Shared services in `AppCore`

- **Job queue:** an actor that runs jobs one at a time by default (the hardware encoder is the bottleneck), supports cancel, reports progress, posts a user notification on completion when the app isn't frontmost, and keeps the Mac from sleeping during a run.
- **Inputs/outputs:** a file input (security-scoped URL) and a Photos input (asset identifier) behind one abstraction; output destinations: next to original, chosen folder, back to Photos as new item, or Replace.
- **Metadata model:** a normalized inventory of everything the app knows how to detect in a file (§8.3), used both for the pre-run report and the post-run verification.
- **Verification:** after each job, re-inspect the output and diff its inventory against the source's; any unexpected loss marks the job "Completed with warnings" and shows what's missing.

### 7.4 Technology choices

- Swift 6.4, strict concurrency (complete checking), `@Observable` models, SwiftUI `NavigationSplitView`, `MenuBarExtra`, `Settings` scene.
- AVFoundation (`AVAssetReader`/`AVAssetWriter` for full control over tracks and metadata) + VideoToolbox for encoding settings.
- PhotoKit for library read/write and revertible edits.
- App Intents for Shortcuts; a Finder-integrated action for right-click.
- Swift Testing for tests; swift-format for style; GitHub Actions on macOS runners for build/test/release.
- Sparkle 2 for updates, appcast hosted from GitHub (Releases or Pages).

## 8. First tool: Downscale Video

### 8.1 Inputs
- Drag-drop onto the window, onto the menu bar icon, or onto the Dock icon; Choose Files…; **From Photos…**; Finder right-click on one or many videos; Shortcuts.
- Accepted: QuickTime (`.mov`), MPEG-4 (`.mp4`, `.m4v`). Primary target is iPhone footage; other sources should work on a best-effort basis but aren't the focus.
- Multiple files at once → one queue.
- **Photos inputs use the edited version (owner decision).** If the user trimmed, filtered, or otherwise edited the video in Photos, the 1080p output must show those edits — the edits are baked into the new video. Unedited videos use the original. The report notes "from your edited version." Use Photos' own rendering of the current version so the result matches what the user sees.
- iCloud-only originals ("Optimize Mac Storage"): ask Photos to download them, show download progress, allow cancel, clear error when offline.
- **iPhone workflow = iCloud Photos (owner decision, 2026-11-25).** The owner uses iCloud Photos, so the iPhone's library *is* the Mac's Photos library; aarik works only through PhotoKit on the Mac and Replace syncs to the iPhone via iCloud. No USB/"connected iPhone" mode (macOS cannot write videos back into an iPhone's camera roll over a cable).
- **Special iPhone formats (my calls):**
  - *Spatial video* (two-view HEVC): detected and **refused** with a clear message in v1 — never silently drop the second eye.
  - *Slo-mo*: frame rate is locked to the source (the frame-rate setting is disabled for these clips); the Photos speed ramp comes through via the edited-version rule above, and the report says so.
  - *ProRes / Apple Log*: supported; HEVC output keeps 10-bit and copies the source's color tags as-is (Log is not "converted" to HDR).
  - *Live Photo videos*: the pairing identifier is kept on exported files; downscaling the video half of a Live Photo inside Photos is out of scope.

### 8.2 Settings (revised 2026-11-25: presets + estimates, owner decision)
The primary control is a **quality preset**, chosen globally in the header and overridable per clip in the inspector. Every clip shows its **estimated output size and % saved for each preset before anything runs**.

| Preset | Resolution | Target | Notes |
|---|---|---|---|
| **High** | keep source resolution (4K stays 4K) | ~50% of source bitrate | biggest, safest |
| **Balanced** (default) | 1080p short side | bitrate scaled to pixel rate (≈ 8–10 Mbps @1080p30 HEVC 10-bit) | the everyday choice |
| **Smaller** | 1080p short side | ≈ 60% of Balanced | for archives / sharing |

Exact bitrate tables are the builder's call; they must scale with resolution × frame rate and must produce a meaningful saving (the 20 Mbps engine default saved only ~22% on a real 4K30 clip).

**Advanced** (disclosure in the inspector): resolution (720p / 1080p / 1440p / custom), format (**HEVC — keep HDR** default, or **H.264 — compatible**: SDR, tone-mapped), bitrate or target size, frame rate (same, or lower standard rate; never upsample).

**Kept As Is:** if a clip's estimated saving is under **10%**, or the clip is already at/below the preset's resolution and bitrate, it isn't converted; it goes to *Kept As Is* with the reason. Never upscale.

**Estimates:** a fast estimate from duration × preset bitrate (+ passthrough audio/metadata size). An optional **Measure Exactly** action encodes short samples with the real settings for a tighter number (builder may defer to Plan 3+).

**Save to** (Local Files): next to original (default) / chosen folder / Replace and free space (§8.5).

Output naming for files: `IMG_4211 (1080p).mov`, never overwriting an existing file (append a counter). Container matches the source unless the format requires otherwise.

### 8.3 Metadata to preserve (iPhone focus)
The inventory the planner and verifier work from:

- **File-level QuickTime metadata:** make, model, software, lens model/focal length, creation date with time zone, location (ISO 6709) and accuracy, Live Photo content identifier, any other `com.apple.quicktime.*` keys (copy all unknown keys too).
- **Video track:** color primaries / transfer / matrix, HDR type, **Dolby Vision configuration and per-frame metadata**, orientation/transform, timecode if present.
- **Audio tracks:** all of them, **passed through without re-encoding** (keeps spatial audio / multichannel / APAC intact).
- **Timed metadata tracks:** copied where they're not resolution-dependent.
- **File system:** creation/modification dates, Finder tags and other extended attributes on the output file mirror the source.
- **Photos:** when saving to Photos, the new asset carries the source's creation date, location, favorite status, hidden status, and album memberships.

**Expected losses (reported, not hidden):** Cinematic-mode depth/disparity data (can't be resized meaningfully), any timed metadata tied to pixel coordinates, HDR when the user picks H.264, and — on Replace in Photos — Photos-only data tied to the old asset (e.g. shared-album comments/likes, the ability to revert or re-edit the original edits). The builder should confirm the exact list against real files (see §10); anything that turns out to be preservable moves to "kept."

### 8.3a Dolby Vision is a release gate (owner decision)
Preserving Dolby Vision through a resize is **non-negotiable for v1.** If Apple's frameworks alone can't carry the per-frame Dolby Vision metadata (RPU) through a resize correctly, v1 does not ship with a plain-HDR fallback; instead the builder pursues another route — for example extracting the source RPU, adjusting the resolution-dependent parts (e.g. active-area / L5 offsets), and re-attaching it to the VideoToolbox HEVC output, possibly with an open-source RPU tool such as `dovi_tool` (MIT) — until DV survives and is verified on real iPhone fixtures.

Consequences:
- The **spike (§10) is a go/no-go gate** on the whole Downscale Video tool and comes before all UI work.
- The output must be checked as genuine Dolby Vision (DV configuration present, per-frame metadata present, plays as Dolby Vision in Photos / QuickTime on Apple devices), not merely "has HDR."
- **Exception (my call, flagged for the owner):** for *edited* Photos videos, the edits come first (owner's rule in §8.1). If Photos' rendering of an edited video cannot carry Dolby Vision, that clip's report says "Dolby Vision will be lost (edited version)" rather than blocking. The spike must test this case.

### 8.4 Report UI (owner chose "both")
- Each queue row shows a badge: **All kept** / **N will be lost** / after running: **Verified** / **Completed with warnings**.
- Clicking a badge shows the full report (kept / will change / lost).
- An **inspector panel** (toggle in toolbar, like Finder's preview pane) shows the full report for the selected clip at all times when open.
- Pressing Convert when any job would lose something shows a confirmation sheet naming what's lost per file, with **Skip This Video** / **Convert Anyway**.

### 8.5 Replace and free space (owner: the main purpose is freeing Photos/iCloud storage)
- **Finder:** output written and verified, then the original is **moved to Trash** (not deleted) and the output takes its name.
- **Photos:** output saved as a **new asset** (with date, location, favorite, hidden, albums copied per §8.3), verified, then the original asset is **deleted via Photos**, which shows the system's own confirmation and moves it to **Recently Deleted** (recoverable for 30 days; space is freed once it leaves Recently Deleted). A revertible edit is *not* used, because it keeps the full-size original and saves no space.
- **Originals backup (owner decision, 2026-11-25):** an optional setting, *Keep a copy of originals*, saves each untouched original to a folder (default `~/Movies/<App Name> Originals/`, user can pick an external drive) **before** any replace; files are never overwritten (counter suffix). The replace only proceeds once the backup copy is written and its size verified.
- The UI says plainly that iCloud space is freed only when Recently Deleted is emptied or after 30 days.
- If verification fails, the original is never touched.
- Batch-friendly: one system confirmation for the whole batch where Photos allows it.
- aarik shows the space saved (before → after, total) when the batch finishes.

### 8.5a Quick runs from Finder, Shortcuts and the menu bar (owner decision)
- These entry points **convert immediately in the background** using the tool's saved default settings — no window opens.
- **Loss policy: skip.** Any file whose report has a "will be lost" entry is skipped, not converted. A notification lists converted and skipped files; clicking it opens aarik with the skipped files queued so the user can review and decide.
- The Shortcuts action returns the output file(s) so it can feed later steps, and exposes the settings (resolution, format, destination) as optional parameters.
- Where the work actually runs (inside the app process launched in the background vs. in the extension) is the builder's call, but there must be one shared queue so two quick runs don't encode in parallel.
- **Shipping (my call):** the main window, Photos, and the menu bar are required for v1. If Finder right-click or Shortcuts prove unreliable without a proper code signature, they move to the first signed release rather than blocking v1.

### 8.6 After a run
- Progress per item and overall; cancel item / cancel all.
- Notification on completion if the app isn't frontmost.
- Result row: size before → after, Verified / warnings, Show in Finder / Show in Photos.

## 9. App shell and UI (revised 2026-11-25: hybrid layout, owner decision)

Research (KeepFeather, Swivel, Permute, HandBrake, Photos space-savers) led the owner to a **hybrid** shape: library-first for media (inspired by KeepFeather's *layout*, not its look, name, icon or copy) plus a toolbox for everything else. Approved mockup: `.superpowers/brainstorm/*/content/shell-v1.html` (local).

```
┌──────────────────┬───────────────────────────────────────────┬────────────────────┐
│ Library          │ Could free about 12.1 GB   [High|Balanced|Smaller]           │
│  Overview        │ ████████░░░░  18.6 GB now → ≈6.5 GB after  │  preview           │
│  Videos (Photos) │ August 2026 · 9 videos                     │  IMG_4211.MOV      │
│  Local Files     │ ┌────┐┌────┐┌────┐┌────┐  tiles: thumbnail, │  DV 8.4 · Location │
│ Media types      │ │DV4K││DV  ││SLO ││SDR │  badges (DV, 4K,   │  Quality:          │
│  Dolby Vision    │ │1.2G││890M││640M││310M│  Cinematic, Slo-mo,│   Original 1.2 GB  │
│  Cinematic …     │ └────┘└────┘└────┘└────┘  Spatial, Edited), │   High  ≈620MB −48%│
│ Tools            │                           size label       │  ◉Bal.  ≈260MB −78%│
│  Downscale Video │                                            │   Small ≈170MB −86%│
│  (more later)    │                                            │  Advanced ▸        │
│ Activity         │                                            │  Metadata: kept/…  │
│  Queue · Completed · Kept As Is · Failed                       │ [+ Add to Queue]   │
└──────────────────┴───────────────────────────────────────────┴────────────────────┘
```

- **Sidebar sections:** *Library* (Overview — savings dashboard; Videos — Photos library, Plan 3; Local Files — folders/files the user added), *Media types* (filters: Dolby Vision, Cinematic, Slo-mo, Spatial, Edited, …; shown only when non-empty), *Tools* (Downscale Video now; Convert Image / PDF / Office later — tool pages for non-media work), *Activity* (Queue, Completed, Kept As Is, Failed — each with counts).
- **Grid:** Photos-like tiles grouped by month (Years / Months / All), sort Biggest first / Newest first, size label + badges; multi-select; Space = Quick Look preview; arrow keys; search by name. Optional list view.
- **Header:** "Could free about X GB" for what's shown, with the preset switch and a bar of now → after.
- **Inspector** (toggleable, right): preview, name/date/resolution/fps/duration, badges, per-preset estimates with % saved, Advanced disclosure, the metadata kept/changes/lost summary (§8.4 — badges + inspector), **Add to Queue · <preset>**, **Compare with Original** (side-by-side; may be deferred to a later plan).
- **Activity:** the queue runs one job at a time (persists across launches), Pause / Resume (finishes current job), per-job progress; Completed shows before → after and saved; Kept As Is shows the reason; Failed shows the reason + Retry. Statistics (total saved) may come later.
- **Trust copy** (first run / empty states), plain and short: nothing is changed until you add to the queue; copies keep date, place and albums; originals go to Recently Deleted only after a verified copy exists.
- No-selection and empty states use SF Symbols + one sentence (no illustrations).
- **Menu bar:** an icon that accepts dropped files and offers the matching tools; shows queue progress.
- **Settings window:** default output location, updates on/off, notifications, per-tool defaults.
- UI rules: system controls and colors only, SF Symbols, sentence-case labels, no emoji, full keyboard operation (⌘O open, ⌘⏎ convert, ⌘. cancel), VoiceOver labels on everything, respects Reduce Motion / Increase Contrast, light and dark.

## 10. Testing and quality

- **Unit tests** (Swift Testing) for planners, settings, naming, metadata diffing — no media needed.
- **Integration tests** that run real conversions on short fixture clips and assert on the output's metadata inventory.
- **Fixtures:** short (2–3 s) iPhone clips with location on, covering: Dolby Vision 4K60, Dolby Vision 4K30, Cinematic mode, spatial audio, slo-mo, a Live Photo video, an SDR clip, a spatial video (to test refusal), and **a Dolby Vision clip edited in Photos** (trim + filter). Kept small enough to commit (or via Git LFS if needed). **Owner to provide these from their iPhone.**
- **Spike first — go/no-go gate (§8.3a):** before building UI, prove on real fixtures that a resize preserves genuine Dolby Vision and the metadata list in §8.3, including the edited-video case and the Photos replace-and-delete flow. If Apple's frameworks alone fail on DV, the spike continues with an RPU-reinjection route until it works. Adjust the expected-loss list from what's learned.
- CI: build + test on every PR; release workflow builds the DMG, signs the Sparkle update, publishes to GitHub Releases.

## 10a. Phase order (revised 2026-11-25)
1. Plan 1 — engine + Dolby Vision gate (done).
2. **Plan 2 — app shell:** brand config, hybrid sidebar, Local Files grid, presets + estimates, inspector, queue + Activity lists, Settings, partial-file output (atomic rename), H.264 path.
3. **Plan 3 — Photos library:** Overview dashboard, Videos grid from PhotoKit (metadata-only scan, no iCloud download until queued), edited-version input, save-as-new, originals backup folder, replace via Recently Deleted.
4. Plan 4 — Finder right-click, menu bar, Shortcuts.
5. Plan 5 — release (CI, DMG, Sparkle, README).

## 11. Roadmap after v1 (each a new feature module)

1. Convert / resize image (HEIC, JPEG, PNG, AVIF, WebP; keep EXIF/GPS) — ImageIO.
2. PDF: merge, split, compress, reorder, rotate — PDFKit.
3. Office → PDF via **optional LibreOffice download** on first use (~300 MB, user-approved).
4. Later candidates: trim video without re-encoding, extract audio, make GIF.

## 12. Decisions made by me (owner may override)

- Apple Silicon only.
- Sparkle 2 as the sole runtime dependency; no FFmpeg.
- Audio is always passed through, never re-encoded.
- One job at a time by default.
- Default output: next to the original, `name (1080p).ext`; Photos inputs default to saving back to Photos as a new item.
- Spike to validate Dolby Vision/metadata preservation before UI work.
- Edited Photos videos may report Dolby Vision as lost if Photos' rendering can't keep it (the one exception to the DV gate).
- Spatial video refused in v1; slo-mo frame rate locked; ProRes/Log supported with tags copied.
- Live Photo: keep pairing ID only; no in-Photos Live Photo downscaling.
- iCloud original downloads via Photos are allowed.
- Finder right-click / Shortcuts may slip to the first signed release if unsigned builds make them unreliable.
- Docs live in `docs/`; ADRs for significant choices.

## 13. Left to the builder

- Exact `Tool` protocol API and how settings views are composed.
- Exact Finder integration mechanism on macOS 26 (action extension vs. App Intents–backed Quick Action), chosen after checking current APIs.
- Encoder bitrates behind the quality presets.
- How Photos picking is implemented (picker vs. full library access), as long as originals with full metadata are obtained.
- Internal module boundaries inside `MediaEngine`.
- CI details and DMG styling.
