# aarik Plan 1 — Foundation & Dolby Vision Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `AarikKit` Swift package with the metadata model, a media inspector, and a metadata-preserving HEVC downscaler, then run the go/no-go gate: does a 4K→1080p resize of real iPhone footage keep genuine Dolby Vision and everything in spec §8.3?

**Architecture:** Pure Swift package (no app target yet). `AarikCore` holds the pure metadata model and diffing. `MediaEngine` holds `MediaInspector` (file → inventory) and `VideoDownscaler` (AVAssetReader → VTPixelTransferSession scale → VTCompressionSession HEVC encode → passthrough AVAssetWriter; audio and timed-metadata tracks passed through untouched). `MediaTestSupport` generates synthetic fixtures; real iPhone clips are opt-in and never committed. A tiny `aarik-dev` CLI lets the owner inspect and downscale by hand for the manual Dolby Vision check.

**Tech Stack:** Swift 6.4 (strict concurrency), SwiftPM, AVFoundation, VideoToolbox, CoreMedia, Swift Testing, `swift format`. Dev-only: `ffprobe` (Homebrew, already installed) for the RPU frame check script.

**Spec:** `docs/superpowers/specs/2026-11-25-aarik-design.md`

## Plan series

This spec is split into five plans, each producing working, testable software. Only Plan 1 is detailed here; Plans 2–5 are written after the gate, because the gate's outcome decides the engine route they build on.

1. **Foundation & Dolby Vision gate** (this plan) — package, metadata model, inspector, HEVC downscaler, real-clip gate, ADR.
2. **Tool framework + Downscale Video in the app** — `Tool` protocol, `ToolRegistry`, job queue actor, planner/verifier, H.264-compatible path (HDR→SDR tone map), quality presets, naming/never-overwrite, Xcode app shell with `NavigationSplitView` sidebar, queue + badges + inspector + loss confirmation sheet, Settings scene.
3. **Photos** — `PhotosBridge`: picking, edited-version input (+ the edited-DV gate case deferred from this plan), iCloud original download with progress, save-as-new with date/location/favorite/hidden/albums, Replace-and-free-space (save → verify → delete original via Photos), space-saved summary.
4. **Quick runs** — menu bar drop target, Finder right-click, Shortcuts (App Intents returning output files), shared queue, skip-on-loss policy + notifications.
5. **Release** — GitHub Actions build/test, ad-hoc signed DMG, Sparkle 2 appcast + EdDSA keys, README with "Open Anyway" instructions, `docs/adding-a-tool.md`.

## Global Constraints

- macOS 26 minimum; Apple Silicon (arm64) only.
- Swift 6 language mode with complete strict concurrency checking; no warnings suppressed.
- No third-party runtime dependencies in this plan. No FFmpeg in the product (ffprobe is a dev-only check tool).
- Never modify a source file. Never overwrite an existing output (throw instead).
- Audio is always passed through, never re-encoded.
- Real iPhone fixtures live in `Fixtures/iphone/` and are git-ignored (they contain the owner's location). Tests that need them are skipped when absent.
- Dolby Vision preservation through a resize is a **release gate** (spec §8.3a). Failure stops this plan's track; it is not papered over with an HDR fallback.
- License header not required per file; repo is GPL-3.0.

## Review Focus

1. **Portrait iPhone clips** (stored landscape with a 90° rotation transform): "1080p" must mean short side 1080, and the rotation must survive — owner expects a 1080×1920 portrait video. → test in Task 5.
2. **Source already at or below target** (e.g. a 1080p clip asked to go to 1080p): must not upscale or silently re-encode; downscaler throws `sourceAlreadySmall`. → test in Task 5.
3. **Cancel mid-conversion:** no half-written output left on disk. → test in Task 5.
4. **Unknown/unusual QuickTime keys** (Apple adds new `com.apple.quicktime.*` keys every year): must be copied, not filtered to a known list. → test in Task 5.
5. **60 → 30 fps reduction:** output duration must match source within one frame and audio must stay in sync. → test in Task 5.

---

## File Structure

```
.gitignore                                   (exists)
LICENSE                                      GPL-3.0 text
README.md                                    one-paragraph stub
.swift-format                                formatter config
Packages/AarikKit/
  Package.swift
  Sources/
    AarikCore/
      Metadata/MetadataItem.swift            MetadataCategory, MetadataItem
      Metadata/MetadataInventory.swift       MetadataInventory
      Metadata/MetadataReport.swift          MetadataReport, MetadataChange
      Metadata/MetadataDiff.swift            source vs output → report
    MediaEngine/
      Inspection/MediaInspector.swift        URL → MetadataInventory (orchestrates the readers below)
      Inspection/AssetMetadataReader.swift   file-level QuickTime/udta items
      Inspection/TrackInspector.swift        per-track format, color, HDR, transform, stereo
      Inspection/DolbyVisionConfig.swift     parse dvcC/dvvC record
      Inspection/FileAttributes.swift        tags, xattrs, dates (read + copy)
      Downscale/DownscaleSpec.swift          DownscaleSpec, DownscaleError, output size math
      Downscale/VideoDownscaler.swift        orchestration: reader/writer, tracks, progress, cancel
      Downscale/HEVCEncoder.swift            VTCompressionSession wrapper → CMSampleBuffers
      Downscale/FrameScaler.swift            VTPixelTransferSession wrapper
      Downscale/FrameRateLimiter.swift       drop-frame decision
    MediaTestSupport/
      FixtureFactory.swift                   synthetic clips via AVAssetWriter
      RealFixtures.swift                     locate optional iPhone clips
    aarik-dev/
      main.swift                             `inspect` and `downscale` subcommands
  Tests/
    AarikCoreTests/MetadataDiffTests.swift
    MediaEngineTests/FixtureFactoryTests.swift
    MediaEngineTests/MediaInspectorTests.swift
    MediaEngineTests/DolbyVisionConfigTests.swift
    MediaEngineTests/DownscaleSpecTests.swift
    MediaEngineTests/FrameRateLimiterTests.swift
    MediaEngineTests/VideoDownscalerTests.swift
    MediaEngineTests/RealClipGateTests.swift
scripts/dv-check.sh                          ffprobe RPU-per-frame check
docs/adr/0001-dolby-vision-downscale-route.md
```

All `swift` commands below run from `Packages/AarikKit/`.

---

### Task 1: Repository and package skeleton

**Files:**
- Create: `LICENSE`, `README.md`, `.swift-format`, `Packages/AarikKit/Package.swift`, one placeholder source file per target, `Tests/AarikCoreTests/MetadataDiffTests.swift` (smoke test only)

**Interfaces:**
- Produces: SwiftPM targets `AarikCore`, `MediaEngine` (depends on `AarikCore`), `MediaTestSupport` (depends on `MediaEngine`), executable `aarik-dev` (depends on `MediaEngine`, `MediaTestSupport`), test targets `AarikCoreTests` (→ `AarikCore`), `MediaEngineTests` (→ `MediaEngine`, `MediaTestSupport`).

- [ ] **Step 1:** Fetch the GPL-3.0 text from `https://www.gnu.org/licenses/gpl-3.0.txt` into `LICENSE`. Write `README.md`: name, one sentence ("A free, offline, open-source Mac toolbox for converting video, images, PDFs and documents without losing metadata."), "Status: early development", "License: GPL-3.0".
- [ ] **Step 2:** Write `Package.swift` with `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, the targets above, and `swiftSettings: [.swiftLanguageMode(.v6)]` on every target.
- [ ] **Step 3:** Write `.swift-format` (JSON): `lineLength` 120, `indentation` 4 spaces, `respectsExistingLineBreaks` true, `rules.AllPublicDeclarationsHaveDocumentation` false.
- [ ] **Step 4:** Add a smoke test `@Test func packageBuilds() { #expect(true) }` and run `swift build && swift test`. Expected: build succeeds, 1 test passes, zero warnings.
- [ ] **Step 5:** Run `swift format lint -r Sources Tests`. Expected: no output.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "chore: bootstrap AarikKit package, license, readme"` (this also commits the spec, plan and `.gitignore`).

---

### Task 2: Metadata model and diff (AarikCore)

**Files:**
- Create: `Sources/AarikCore/Metadata/*.swift`
- Test: `Tests/AarikCoreTests/MetadataDiffTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum MetadataCategory: String, Codable, Sendable, CaseIterable {
      case camera, location, date, video, hdr, audio, timedMetadata, track, fileSystem, other
  }
  public struct MetadataItem: Hashable, Codable, Sendable {
      public let key: String          // stable, namespaced (see key scheme)
      public let category: MetadataCategory
      public let displayName: String  // sentence case, user-facing
      public let value: String        // normalized, comparable
  }
  public struct MetadataInventory: Codable, Sendable, Equatable {
      public var items: [MetadataItem]
      public subscript(key: String) -> MetadataItem? { get }
  }
  public struct MetadataChange: Hashable, Codable, Sendable {
      public let key: String; public let displayName: String; public let from: String; public let to: String
  }
  public struct MetadataReport: Codable, Sendable, Equatable {
      public var kept: [MetadataItem]; public var changed: [MetadataChange]; public var lost: [MetadataItem]
      public var isLossless: Bool { get }   // lost.isEmpty
  }
  public enum MetadataDiff {
      public static func report(source: MetadataInventory, output: MetadataInventory) -> MetadataReport
  }
  ```
- **Key scheme** (used by every later task): `qt.<full key>` file-level QuickTime/udta item (e.g. `qt.com.apple.quicktime.make`); `video.dimensions` (`"3840x2160"`), `video.frameRate` (`"59.94"`, 2 decimals), `video.codec` (FourCC, e.g. `"hvc1"`), `video.colorPrimaries` / `video.transferFunction` / `video.matrix` (CoreMedia constant string), `video.transform` (`"a,b,c,d,tx,ty"` integers), `video.bitDepth`; `hdr.dolbyVision` (`"profile 8, level 9, compat 4"`); `hdr.stereo` (`"left+right"`); `audio.<n>.format` (FourCC), `audio.<n>.channels`, `audio.<n>.sampleRate`; `timed.<identifier>` (`"present"`); `track.<n>.kind` (`"<mediaType>/<subtype>"`) for tracks of other kinds; `fs.tags` (sorted, comma-joined), `fs.xattr.<name>` (SHA-256 hex of value), `fs.creationDate` (ISO 8601).

- [ ] **Step 1: Write failing tests** in `MetadataDiffTests`:
  - `identicalInventoriesAreLossless`: same 3 items both sides → `kept.count == 3`, `changed.isEmpty`, `lost.isEmpty`, `isLossless`.
  - `missingKeyIsLost`: source has `qt.com.apple.quicktime.location.ISO6709`, output doesn't → it's in `lost`, `!isLossless`.
  - `differentValueIsChanged`: `video.dimensions` `"3840x2160"` → `"1920x1080"` → one `MetadataChange(from: "3840x2160", to: "1920x1080")`, not in `kept` or `lost`.
  - `extraOutputKeysIgnored`: output-only key appears nowhere in the report.
  - `reportOrderFollowsSource`: `kept` order equals source item order.
- [ ] **Step 2:** `swift test --filter MetadataDiffTests` → FAIL (types undefined).
- [ ] **Step 3:** Implement the types and `MetadataDiff.report` per the signatures above.
- [ ] **Step 4:** `swift test --filter MetadataDiffTests` → 5 PASS.
- [ ] **Step 5: Commit** — `feat(core): metadata inventory, report, and diff`.

---

### Task 3: Synthetic fixture factory

**Files:**
- Create: `Sources/MediaTestSupport/FixtureFactory.swift`, `Sources/MediaTestSupport/RealFixtures.swift`
- Test: `Tests/MediaEngineTests/FixtureFactoryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum FixtureHDR: Sendable { case sdr, hlg }
  public struct ClipOptions: Sendable {
      public var width = 3840, height = 2160, fps = 30, seconds = 1.0
      public var hdr: FixtureHDR = .hlg
      public var quickTimeMetadata: [String: String] = [:]   // key → string value, keySpace mdta
      public var includeAudio = true                         // stereo AAC 48 kHz
      public var includeTimedMetadataTrack = false            // one mebx track, identifier "mdta/com.aarik.test.timed"
      public var rotationDegrees = 0                          // 0 or 90 → preferredTransform
      public var finderTags: [String] = []
      public var extendedAttributes: [String: Data] = [:]
  }
  public enum FixtureFactory {
      /// Writes a new .mov into a fresh temporary directory and returns its URL.
      public static func makeClip(_ options: ClipOptions = .init()) async throws -> URL
  }
  public enum RealFixture: String, CaseIterable, Sendable {
      case dolbyVision4K60 = "dv-4k60.mov", dolbyVision4K30 = "dv-4k30.mov", cinematic = "cinematic.mov",
           spatialAudio = "spatial-audio.mov", sloMo = "slomo.mov", livePhoto = "live-photo.mov",
           sdr = "sdr.mov", spatialVideo = "spatial-video.mov"
  }
  public enum RealFixtures {
      /// `<repo>/Fixtures/iphone/<name>` resolved from #filePath, or nil if absent.
      public static func url(_ fixture: RealFixture) -> URL?
  }
  ```
- HLG clips: HEVC Main10, `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`, color properties ITU_R_2020 / ITU_R_2100_HLG / ITU_R_2020. SDR clips: HEVC Main, ITU_R_709_2 throughout. Frames: a moving gradient so the encoder produces real data.

- [ ] **Step 1: Write failing tests:**
  - `makesHLGClipWithRequestedShape`: default options → file exists, video track natural size 3840×2160, format description transfer function == `kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG`, duration ≈ 1.0 s (±0.05).
  - `writesQuickTimeMetadata`: `quickTimeMetadata = ["com.apple.quicktime.make": "Apple", "com.apple.quicktime.location.ISO6709": "+12.9716+077.5946+000.000/"]` → `asset.load(.metadata)` contains both with those values.
  - `appliesRotationTagsAndXattrs`: `rotationDegrees = 90`, `finderTags = ["Red"]`, `extendedAttributes = ["com.aarik.test": Data("x".utf8)]` → transform is a 90° rotation; tag and xattr readable.
- [ ] **Step 2:** `swift test --filter FixtureFactoryTests` → FAIL.
- [ ] **Step 3:** Implement `FixtureFactory.makeClip` (AVAssetWriter; Finder tags via `URLResourceValues.tagNames`; xattrs via `setxattr`) and `RealFixtures.url`.
- [ ] **Step 4:** `swift test --filter FixtureFactoryTests` → 3 PASS.
- [ ] **Step 5: Commit** — `test: synthetic fixture factory and real-fixture locator`.

---

### Task 4: Media inspector

**Files:**
- Create: `Sources/MediaEngine/Inspection/*.swift`
- Test: `Tests/MediaEngineTests/MediaInspectorTests.swift`, `Tests/MediaEngineTests/DolbyVisionConfigTests.swift`

**Interfaces:**
- Consumes: `MetadataInventory`, `MetadataItem`, key scheme (Task 2); `FixtureFactory` (Task 3).
- Produces:
  ```swift
  public struct MediaInspector: Sendable {
      public init()
      public func inventory(of url: URL) async throws -> MetadataInventory
  }
  public struct DolbyVisionConfig: Equatable, Sendable {
      public let profile: Int, level: Int, rpuPresent: Bool, elPresent: Bool, blPresent: Bool, compatibilityID: Int
      public init?(record: Data)          // body of a dvcC/dvvC/dvwC atom
      public var displayValue: String { get }   // "profile 8, level 9, compat 4"
  }
  enum FileAttributes {
      static func read(_ url: URL) throws -> [MetadataItem]       // fs.* items
      static func copy(from source: URL, to destination: URL) throws  // tags, all xattrs except com.apple.quarantine, creation + modification dates
  }
  ```
- `DolbyVisionConfig` parsing (big-endian): byte 0 = version major, byte 1 = version minor; bits of bytes 2–3: `profile` = top 7 bits, `level` = next 6, then `rpuPresent`, `elPresent`, `blPresent` (1 bit each); `compatibilityID` = top 4 bits of byte 4. Record must be ≥ 5 bytes or init returns nil.
- DV detection: video format description extension `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`, keys `dvcC`, `dvvC`, or `dvwC`.
- Stereo detection: `kCMFormatDescriptionExtension_HasLeftStereoEyeView` / `HasRightStereoEyeView` both true → `hdr.stereo = "left+right"`.
- Every file-level metadata item is emitted (no allow-list). Item values: `stringValue`, else `numberValue`, else `dateValue` ISO 8601, else SHA-256 hex of `dataValue`.
- Display names: sentence case, e.g. "Camera make", "Location", "Dolby Vision", "Audio track 1 format"; unknown `qt.` keys use the last dotted component.

- [ ] **Step 1: Write failing tests:**
  - `DolbyVisionConfigTests.parsesProfile8_4`: record bytes `[0x01, 0x00, 0x10, 0x35, 0x40]` → profile 8, level 6, rpu true, el false, bl true, compat 4; `displayValue == "profile 8, level 6, compat 4"`.
  - `DolbyVisionConfigTests.rejectsShortRecord`: 4 bytes → nil.
  - `inventoriesHLGClip`: default fixture → `video.dimensions == "3840x2160"`, `video.transferFunction` is the HLG constant, `video.bitDepth == "10"`, `audio.0.channels == "2"`, no `hdr.dolbyVision` key.
  - `inventoriesAllQuickTimeKeysIncludingUnknown`: fixture with `com.apple.quicktime.make` and `com.apple.quicktime.some-future-key` → both `qt.` keys present with values.
  - `inventoriesFileSystemAttributes`: tags `["Red","Blue"]` → `fs.tags == "Blue,Red"`; one xattr → `fs.xattr.<name>` present.
  - `inventoriesTimedMetadataTrack`: `includeTimedMetadataTrack = true` → `timed.mdta/com.aarik.test.timed == "present"`.
- [ ] **Step 2:** `swift test --filter "MediaInspectorTests|DolbyVisionConfigTests"` → FAIL.
- [ ] **Step 3:** Implement the inspection files per the interfaces.
- [ ] **Step 4:** Same command → 6 PASS.
- [ ] **Step 5: Commit** — `feat(engine): media inspector with Dolby Vision, stereo, and file attribute detection`.

---

### Task 5: HEVC downscaler (keep HDR)

**Files:**
- Create: `Sources/MediaEngine/Downscale/*.swift`
- Test: `Tests/MediaEngineTests/DownscaleSpecTests.swift`, `FrameRateLimiterTests.swift`, `VideoDownscalerTests.swift`

**Interfaces:**
- Consumes: `MediaInspector`, `FileAttributes.copy`, `MetadataDiff` (Tasks 2, 4); `FixtureFactory` (Task 3).
- Produces:
  ```swift
  public struct DownscaleSpec: Sendable, Equatable {
      public var targetShortSide: Int = 1080
      public var averageBitRate: Int = 20_000_000
      public var maxFrameRate: Double? = nil          // nil = same as source; never increases
      public init(targetShortSide: Int = 1080, averageBitRate: Int = 20_000_000, maxFrameRate: Double? = nil)
      /// Encoded (pre-transform) output size: short side = target, aspect kept, both even.
      public func outputSize(forNaturalSize: CGSize) -> CGSize
  }
  public enum DownscaleError: Error, Equatable, Sendable {
      case outputExists, sourceAlreadySmall, unsupportedSource(String), encoderFailed(String)
  }
  struct FrameRateLimiter {
      init(maxFrameRate: Double?)
      mutating func shouldKeep(presentationTime: CMTime) -> Bool
  }
  public struct VideoDownscaler: Sendable {
      public init()
      public func downscale(source: URL, output: URL, spec: DownscaleSpec,
                            progress: @escaping @Sendable (Double) -> Void) async throws
  }
  ```
- Pipeline decisions:
  - Throw `outputExists` before reading if `output` exists. Throw `sourceAlreadySmall` if the source short side ≤ `targetShortSide`. Throw `unsupportedSource("spatial video")` if `hdr.stereo` is present.
  - Video: `AVAssetReaderTrackOutput` decoding to `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` → `FrameScaler` (VTPixelTransferSession, same pixel format, copies color attachments) → `HEVCEncoder` (VTCompressionSession: HEVC Main10 auto level, `averageBitRate`, real-time false, color primaries/transfer/matrix copied from source format description) → compressed sample buffers appended to an `AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint:)` whose `transform` = source `preferredTransform`.
  - **Dolby Vision route A (the gate's first candidate):** when the source has `hdr.dolbyVision` with HLG transfer, set `kVTCompressionPropertyKey_HDRMetadataInsertionMode = kVTHDRMetadataInsertionMode_Auto` and `kVTCompressionPropertyKey_PreserveDynamicHDRMetadata = true` on the session. The encoder's own output format description (with its `dvvC`/`dvcC` atom) becomes the writer input's `sourceFormatHint`.
  - Audio and timed-metadata tracks: `AVAssetReaderTrackOutput(outputSettings: nil)` → `AVAssetWriterInput(outputSettings: nil, sourceFormatHint:)`; timed-metadata inputs get `addTrackAssociation(withTrackOf: videoInput, type: .metadataReferent)`. Other track kinds are skipped (they'll appear as lost in the report).
  - File level: `writer.metadata = asset.load(.metadata)`; file type `.mov`; after `finishWriting`, `FileAttributes.copy(from:to:)`.
  - Frame-rate limiting (`FrameRateLimiter`): keep a frame iff `pts >= nextAllowed`; on keep, `nextAllowed = max(nextAllowed + 1/maxFrameRate, pts + 1/maxFrameRate − tolerance)` with tolerance = 1/(4·maxFrameRate); `nil` keeps all.
  - Progress: `pts / duration` after each appended video frame, monotonic, final call `1.0`.
  - Cancellation: check `Task.isCancelled` per frame; on cancel or any error, `cancelWriting()`, delete `output`, rethrow (`CancellationError` for cancel).

- [ ] **Step 1: Write failing unit tests:**
  - `DownscaleSpecTests.landscape4KTo1080`: 3840×2160 → 1920×1080.
  - `DownscaleSpecTests.oddAspectRoundsToEven`: 4096×2160 → 2048×1080.
  - `DownscaleSpecTests.portraitStoredUprightUsesShortSide`: 2160×3840 → 1080×1920.
  - `FrameRateLimiterTests.halves60To30`: 60 frames at 1/60 s spacing, max 30 → exactly 30 kept, first kept.
  - `FrameRateLimiterTests.nilKeepsAll` and `FrameRateLimiterTests.handlesJitter`: timestamps with ±2 ms jitter at 60 fps, max 30 → 30 kept (±1).
- [ ] **Step 2:** `swift test --filter "DownscaleSpecTests|FrameRateLimiterTests"` → FAIL; implement `DownscaleSpec`, `FrameRateLimiter`; rerun → PASS.
- [ ] **Step 3: Write failing integration tests** in `VideoDownscalerTests` (each `.timeLimit(.minutes(2))`):
  - `hlg4KTo1080KeepsEverything`: fixture with QuickTime make/model/location/creationdate, audio, timed-metadata track, Finder tag, one xattr → downscale → `MetadataDiff.report(source, output)`: `lost.isEmpty`; `changed` keys ⊆ {`video.dimensions`}; `video.dimensions == "1920x1080"`; transfer function still HLG; `video.bitDepth == "10"`.
  - `unknownQuickTimeKeysSurvive` *(Review Focus 4)*: key `com.apple.quicktime.some-future-key` = `"42"` → present in output with `"42"`.
  - `portraitRotationPreserved` *(Review Focus 1)*: `rotationDegrees = 90` → output natural size 1920×1080 and transform equals source transform.
  - `refusesToUpscale` *(Review Focus 2)*: 1920×1080 source, target 1080 → throws `DownscaleError.sourceAlreadySmall`; output does not exist.
  - `refusesExistingOutput`: output path pre-created → throws `.outputExists`; pre-existing file unchanged.
  - `cancelRemovesPartialOutput` *(Review Focus 3)*: 4 s fixture; cancel the task when progress first exceeds 0.1 → throws `CancellationError`; output does not exist.
  - `sixtyToThirtyKeepsDurationAndSync` *(Review Focus 5)*: 60 fps, 2 s fixture, `maxFrameRate: 30` → `video.frameRate == "30.00"`, video duration within 1/30 s of source, audio duration within 1/30 s of video.
  - `audioIsPassedThrough`: source and output `audio.0.format`, `audio.0.channels`, `audio.0.sampleRate` identical.
- [ ] **Step 4:** `swift test --filter VideoDownscalerTests` → FAIL.
- [ ] **Step 5:** Implement `FrameScaler`, `HEVCEncoder`, `VideoDownscaler` per the pipeline decisions.
- [ ] **Step 6:** `swift test` → all tests PASS, zero warnings.
- [ ] **Step 7: Commit** — `feat(engine): HEVC downscaler with metadata, audio, and timed-metadata passthrough`.

---

### Task 6: `aarik-dev` CLI and RPU check script

**Files:**
- Create: `Sources/aarik-dev/main.swift`, `scripts/dv-check.sh`

**Interfaces:**
- Consumes: `MediaInspector`, `VideoDownscaler`, `DownscaleSpec`, `MetadataDiff`.
- Produces (commands, from `Packages/AarikKit`):
  - `swift run aarik-dev fixture <out>` → writes a default `FixtureFactory` clip (4K HLG, 1 s, with audio) to `<out>`.
  - `swift run aarik-dev inspect <file>` → one line per item: `<category>  <displayName>: <value>`.
  - `swift run aarik-dev downscale <in> <out> [--short-side N] [--max-fps F] [--bitrate B]` → progress percentage on one updating line, then the report: `Kept (n)`, `Changed (n)`, `Lost (n)` sections listing display names; exit code 0 if lossless, 2 if anything lost, 1 on error.
  - `scripts/dv-check.sh <file>` → prints `frames=<N> rpu_frames=<M> config=<dovi profile/level/compat>` using `ffprobe -v error -select_streams v:0 -show_frames -show_entries frame=side_data_list` and `-show_streams` side data; exit 0 iff `N > 0 && N == M`.

- [ ] **Step 1:** Implement `main.swift` with plain `CommandLine.arguments` parsing (no argument-parser dependency); usage text on bad input, exit 1.
- [ ] **Step 2:** `swift run aarik-dev fixture "$TMPDIR/in.mov" && swift run aarik-dev downscale "$TMPDIR/in.mov" "$TMPDIR/out.mov"` → exits 0, prints `Lost (0)`.
- [ ] **Step 3:** Write `scripts/dv-check.sh` (bash, `set -euo pipefail`, checks `ffprobe` exists with a clear message). Run it on the synthetic output → exits non-zero with `rpu_frames=0` (synthetic clips have no DV — this proves the script can fail).
- [ ] **Step 4: Commit** — `feat(dev): aarik-dev inspect/downscale CLI and Dolby Vision RPU check script`.

---

### Task 7: The Dolby Vision gate on real iPhone clips

**Precondition (owner):** copy the iPhone clips into `Fixtures/iphone/` with the `RealFixture` file names (export from Photos with **File → Export → Export Unmodified Original**; AirDrop also works). Edited-clip and Photos-flow checks are deferred to Plan 3.

**Files:**
- Create: `Tests/MediaEngineTests/RealClipGateTests.swift`, `docs/adr/0001-dolby-vision-downscale-route.md`

**Interfaces:**
- Consumes: everything above. Each test is `.enabled(if: RealFixtures.url(<fixture>) != nil)` and `.timeLimit(.minutes(5))`.

- [ ] **Step 1: Write the gate tests:**
  - `dolbyVisionSurvives4K60` and `dolbyVisionSurvives4K30`: inspect source → `hdr.dolbyVision` present with profile 8 and compat 4; downscale to 1080 → output `hdr.dolbyVision` present with profile 8, compat 4 (level may differ — the report treats it as changed, never lost); `lost.isEmpty`.
  - `iPhoneMetadataSurvives` (on `dolbyVision4K30`): every `qt.` key in the source is present in the output with an identical value.
  - `spatialAudioPassesThrough`: all `audio.*` items identical.
  - `spatialVideoIsRefused`: throws `.unsupportedSource("spatial video")`.
  - `sloMoKeepsFrameRate`: `video.frameRate` unchanged with default spec.
  - `livePhotoKeepsContentIdentifier`: `qt.com.apple.quicktime.content.identifier` present in output with the source value.
  - `sdrClipStaysSDR`: `video.transferFunction` unchanged, no `hdr.dolbyVision` in output, `lost.isEmpty`.
  - `cinematicReportsLosses`: run succeeds; record (don't assert) which keys land in `lost` — printed via `print` for the ADR.
- [ ] **Step 2:** `swift test --filter RealClipGateTests` with fixtures present. Record results.
- [ ] **Step 3:** For each DV output, run `scripts/dv-check.sh <output>` → must exit 0 (RPU on every frame).
- [ ] **Step 4 (owner, manual):** open each DV output in QuickTime Player and import into Photos → both show it as Dolby Vision / HDR and it looks like the source. Owner confirms in chat.
- [ ] **Step 5: Decide the gate.**
  - **PASS** (Steps 2–4 all green): write ADR 0001 — "Route A: VideoToolbox HDR metadata insertion" accepted, with the observed kept/lost lists per clip type (these become spec §8.3's confirmed expected-loss list).
  - **FAIL** on any DV check: before stopping, run one diagnostic — `AVAssetExportSession` with `AVAssetExportPresetHEVC1920x1080` on the same clip, then `dv-check.sh` — and record whether Apple's own export keeps DV (tells us whether route A's settings or the route itself is wrong). Write ADR 0001 as "Route A rejected", with evidence, and **stop**: the next plan becomes "Route C: RPU extraction, L5 active-area adjustment, re-injection" (spec §8.3a). Do not start Plan 2.
- [ ] **Step 6: Commit** — `test: Dolby Vision gate on real iPhone clips; ADR 0001` (tests and ADR only; fixtures stay ignored).
