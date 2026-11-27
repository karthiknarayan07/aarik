# Image Conversion inside Convert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or subagent-driven-development to implement this plan milestone-by-milestone cleanly. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full offline, metadata-preserving image & Live Photo conversion into the existing **Convert** tool across macOS, iOS, Share Extension, Menu Bar, Dock, Finder Services, and Shortcuts.

**Architecture:** Generalize library items (`MediaKind`) and Photos browsing (`PhotoAsset`) in `Core` to hold both videos and images cleanly without regressing cold launch on large libraries, while keeping the media processing engines focused (`ImageInspector` & `ImageConverter` alongside `VideoDownscaler`). Wire dedicated image job kinds, planners, `LossCheck`, estimators, and image UI inside `Packages/Tools/Convert` and thin app shells.

**Tech Stack:** Swift 6 (strict concurrency), ImageIO (`CGImageSource`, `CGImageDestination`, auxiliary data), CoreImage (`CIRAWFilter`, `CIContext`), CoreGraphics, PhotoKit (`PHAsset`, `PHAssetCreationRequest`), SwiftUI, Swift Testing.

**Spec:** [2026-11-27-image-conversion-design.md](../specs/2026-11-27-image-conversion-design.md)

## Global Constraints

- Swift 6 complete strict concurrency, zero warnings (`-warnings-as-errors`), `swift format lint --strict` clean.
- Dependencies strictly `Apps -> Tools -> Core`; no third-party dependencies except Sparkle; offline only.
- Never delete or overwrite originals before verification (`STABILITY.md`); Replace moves to Trash or Photos Recently Deleted via `OriginalsDeleter`.
- No real personal media or real PhotoKit writes in tests; generate fixtures via `CoreGraphics`/`ImageIO` and use `FakePhotoStore`.
- App-level screens (`scripts/app-level-screens.txt`) never mention tool words (`Convert`, `Shrink`, `compress`).
- Always verify macOS + iOS Simulator packages + app builds with `IOS_SKIP_TESTING=UITests scripts/verify.sh` and push commits to `origin/plan-2-app-shell` (never touch `main`).

## Review Focus

- **EXIF Orientation & Metadata Strip Traps:** Photos shot in portrait rely on `Orientation = 6/8` TIFF/EXIF tags. Rendering pixels upright during resize must reset `Orientation = 1` without dropping Camera Make/Model, Lens, Focal Length, ISO, Shutter Speed, GPS, IPTC Caption/Copyright, XMP, Capture Date/Offset, or ICC color profile.
- **Target File Size Convergence:** Small/high-frequency images where minimum quality still exceeds a tight KB cap (e.g. `100 KB`) must step resolution down gracefully or report a clean `ImageConversionError` rather than looping infinitely or exceeding the byte limit silently.
- **Live Photo Asset Pairing:** Converting a Live Photo must preserve the QuickTime `com.apple.quicktime.content.identifier` asset pairing key across the still image (`kCGImagePropertyMakerAppleDictionary` / `"17"`) and paired `.mov` so Photos treats the saved pair as a playable Live Photo rather than two disconnected assets.
- **RAW / Alpha / Animated Edge Cases:** Converting RAW/ProRAW (`DNG`, `CR3`, `NEF`, `ARW`) must develop highlights accurately in Display P3; encoding an RGBA image to `JPEG` or an animated `GIF`/`APNG` to a static format must surface upfront warnings in `LossCheck`.
- **Huge Photos Libraries (20k+ assets):** Fetching mixed images + videos at startup must avoid eager iCloud downloads or blocking the main actor so scrolling stays smooth and cold launch stays under 1 s.

---

### Milestone 1: Core Image Engine, Metadata Inspection & Tests (`MediaEngine`, `AppCore`, `MediaTestSupport`)

- [ ] Add `MediaKind`, image metadata/outcome codes (`OutcomeCode`), and `AtomicOutput` support for arbitrary image containers in `AppCore` & `MediaEngine`.
- [ ] Build `ImageSpec.swift`: megapixel presets (`24 MP`, `12 MP`, `5 MP`, `2 MP`, `Keep Original`), scale `%` (`75%`, `50%`, `25%`), custom max W × H, target output format (`keepOriginal`, `heic`, `jpeg`, `png`, `avif`, `tiff`, `gif`), quality (`0...1`), lossless mode, optional `targetByteSize`, Live Photo mode, and pure aspect-preserving size math that never upscales.
- [ ] Build `ImageInspector.swift`: reads image UTIs, pixel sizes (upright after orientation), megapixels, alpha, frame count, RAW flag, HDR Gain Map, Depth/Portrait Matte, ICC profile, and EXIF/TIFF/GPS/IPTC/XMP/MakerNote metadata into `MetadataInventory`.
- [ ] Build `ImageConverter.swift`: `@concurrent` conversion respecting `WorkSlots` and `AtomicOutput`:
  - `CIRAWFilter`/`CIContext` RAW/ProRAW decode.
  - High-quality aspect resize + upright normalization + Orientation=`1`.
  - Full metadata carry-forward (EXIF, TIFF, MakerNote, GPS, IPTC, XMP, ICC profile).
  - HDR Gain Map + Portrait Depth/Matte auxiliary image scaling & carry-forward (HEIC/JPEG Gain Map).
  - Multi-frame animated encode for GIF / PNG (APNG) / HEICS.
  - Binary-search compression quality (and optional adaptive scale-down step) when `targetByteSize` is specified.
- [ ] Extend `MediaTestSupport` with synthetic image fixture generators (HEIC, JPEG, PNG with alpha, animated GIF/APNG, rich EXIF/GPS/IPTC/XMP/ICC tags) and write comprehensive `ImageSpecTests`, `ImageInspectorTests`, and `ImageConverterTests`.
- [ ] Verify Milestone 1 (`cd Packages/Core && swift build -Xswiftc -warnings-as-errors --build-tests && swift test`) and commit on `plan-2-app-shell`.

### Milestone 2: Core Multi-Media Libraries & Photos Live Photo Save (`LocalLibrary`, `PhotosLibrary`)

- [ ] Extend `LibraryItem`, `MediaBadge`, `MediaCollection`, `QualityFilter`, and `LibraryBrowser` for `.video` / `.image`, `MediaKindFilter` (`all`, `videos`, `images`), megapixel buckets (`48 MP+`, `24 MP+`, `12 MP+`, `< 12 MP`), and image traits (`raw`, `livePhoto`, `portrait`, `transparent`, `animated`).
- [ ] Update `LibraryScanner` & `LibraryPersistence` to scan & persist image files alongside videos cleanly.
- [ ] Update `PhotoAsset`, `PhotoSubtypes`, `PhotoStore`, `PhotoKitStore`, `PhotoInputFetcher`, `PhotoItemBuilder`, `PhotosLibrary`, and `PhotoSaver` to fetch images + Live Photos (with paired video), stage both files in `Work/<job-id>/` when preserving Live Photos, save & verify still images (`saveImage`) and Live Photos (`saveLivePhoto` preserving albums, date, location, favorite, caption, subtype), and update `FakePhotoStore`.
- [ ] Add `LocalLibraryTests` & `PhotosLibraryTests` covering mixed video/image scanning, `All`/`Videos`/`Images` filters, MP filter buckets, and `FakePhotoStore` image + Live Photo save/verify failure cleanup.
- [ ] Verify Milestone 2 (`Packages/Core` tests + warnings-as-errors) and commit on `plan-2-app-shell`.

### Milestone 3: Convert Planners, Runners, Overview, Assistant & Entry Points (`Convert`, `QuickRunService`)

- [ ] Extend `ConvertTool` with image job kinds (`convert-image`, `convert-image-photos`, `convert-live-photo`) and `ConvertJobSettings` with `image: ImageConvertSettings?` (preserving all video job JSON compatibility).
- [ ] Implement `ImageAdvancedOptions`, `ImageSavingsCalculator`, `ImageLossCheck`, `ImageConvertRunner`, and Live Photo/Image paths in `PhotosConvertRunner` (respecting 10% savings gate on same-format conversions and allowing explicit format changes cleanly).
- [ ] Update `ConvertModel`, `OverviewSummary`, `OverviewCharts`, `SmartPicks`, `QueryTranslator`/`LibraryFilters`, `OutcomeExplainer`, and `QuickRunService`/`ShrinkVideos` (and `Apps/iOS` Share Extension + `Apps/macOS` Finder/Menu Bar/Dock entries) to support image & mixed video+image batches.
- [ ] Add `ConvertTests` covering MP presets, scale `%`, target size estimates, 10% same-format vs format-change gate, `ImageLossCheck`, mixed queue batches, Photos image/Live Photo runners, and Assistant filters.
- [ ] Verify Milestone 3 (`Packages/Tools/Convert` tests + warnings-as-errors) and commit on `plan-2-app-shell`.

### Milestone 4: macOS & iOS UI, Polish, Full Verification & Build (`ConvertUI`, `Apps/macOS`, `Apps/iOS`)

- [ ] Add top **All / Videos / Images** segmented filter in Mac (`PhotosView`, `LocalFilesView`) & iOS (`IOSPhotosView`, `IOSLocalFilesView`), with adaptive filters/badges/counts/titles.
- [ ] Build iOS & Mac Image Conversion UI (`IOSQualitySections`, `IOSImageQualitySections`, `IOSLibraryInspector`, `LibraryInspector`, `ConvertInspector`, `IOSQueueJobEditor`, `CompareSheet`, `SettingsView`, `IOSSettingsView`): MP presets + scale `%` showing live exact pixels + estimated MB per option, Image More Options (Quality slider + tip, Format, Custom W × H, Target Size, Live Photo mode), stacked Video + Image sections on mixed bulk selections.
- [ ] Update Overview cards/copy, Search prompts, app-level screen wording (`scripts/text-lint.py`), and `CHANGELOG.md`.
- [ ] Run full `IOS_SKIP_TESTING=UITests scripts/verify.sh` + format lint, commit, and push to `origin/plan-2-app-shell`.
