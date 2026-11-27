# Image Conversion inside Convert — Design Spec

Status: Approved in chat (2026-11-27). Extends `2026-11-25-aarik-design.md` and `2026-11-26-ios-and-convert-design.md`.

## Intent

Extend Aarik's existing **Convert** tool on both macOS and iOS so users can inspect, resize, convert, and compress images alongside videos — with resolution choices tailored to photos (megapixels, scale percentages, pixel presets, custom dimensions, and target file size), full native Apple image features, and strict metadata carry-forward and Replace safety matching video conversion.

## Owner Decisions (2026-11-27)

| Topic | Decision |
|---|---|
| Tool placement | Lives inside the existing **Convert** tool (no separate tool). |
| Browsing & navigation | Combined **Photos** and **Files** screens with an **All / Videos / Images** switcher at the top. |
| Sizing & resolutions | Primary picker shows Megapixel/pixel presets (`Keep Original`, `24 MP`, `12 MP`, `5 MP`, `2 MP`) and Scale `%` shortcuts (`75%`, `50%`, `25%`), each showing live resulting pixel dimensions & estimated MB when selected; **Custom max W × H** and **Target File Size** live in More Options. |
| Output formats | Native ImageIO writable formats: `Keep Original` (maps RAW/ProRAW/WebP/BMP/PSD to `HEIC`), `HEIC`, `JPEG`, `PNG` (including APNG), `AVIF`, `TIFF`, and `GIF`. Inputs read all ImageIO-supported types (`WebP`, `ProRAW/DNG`, camera `RAW`, `JXL`, `HEIF/HEIC`, `AVIF`, `JPEG`, `PNG`, `TIFF`, `GIF`, `BMP`, `PSD`). |
| Quality defaults | Default to `Keep Original` format (`RAW`/`WebP` -> `HEIC`) at `80%` quality, with adjustable Quality slider & plain-English guide in More Options. |
| Apple image features | Support **Live Photos** (preserve by shrinking still + paired `.mov` together by default, with an option to flatten to still), **RAW / ProRAW**, **HDR Gain Map**, **Alpha transparency**, **Portrait Depth / Matte**, and **Animated GIF / APNG / HEICS**. |
| Metadata & Replace safety | Carry forward all metadata (EXIF, TIFF, MakerNote, GPS, IPTC, XMP, ICC profile, Gain Map, Depth/Matte, Photos date/location/favorite/albums) and gate Replace Original / Delete Original on a strict `LossCheck` + read-back verification (`STABILITY.md`). |
| Size-savings gate | Keep `"Kept as Is"` when `<10%` smaller while staying in the same format; when intentionally converting to a different output format, save valid converted outputs even if savings are under 10%. |
| Mixed selections | Bulk-selecting both videos and images in `All` shows stacked **Image Settings** and **Video Settings** sections inside Conversion Options / Inspector. |
| Entry points & Overview | Overview totals, charts, Smart Picks, Search/Ask, iOS Share Extension, Mac Dock / Menu Bar / Drag & Drop / Finder Quick Actions / Shortcuts all support images alongside videos. |

## Constraints (Inherited)

- Dependencies strictly one-way: `Apps -> Tools -> Core`.
- Swift 6 complete strict concurrency, zero warnings (`-warnings-as-errors`), `swift format lint --strict` clean.
- No third-party dependencies except Sparkle; offline only.
- Never overwrite or delete user files except verified Replace to Trash / Recently Deleted (`STABILITY.md`).
- No tool names (`Convert`, `Shrink`, `compress`) in app-level screens (`scripts/app-level-screens.txt`).
- All tests use synthetic fixtures (`CoreGraphics`/`ImageIO`) and `FakePhotoStore`, never personal libraries.

## Architecture

### 1. Core Domain & Unified Media Model (`AppCore`, `LocalLibrary`, `PhotosLibrary`)
- **`MediaKind` (`AppCore` / `LocalLibrary`):** `.video` and `.image`, attached to `LibraryItem` alongside lightweight image traits (`isRAW`, `isLivePhoto`, `hasAlpha`, `isAnimated`, `hasDepthMatte`, `hasGainMap`, `formatUTI`). Existing video defaults allow all video call sites & tests to remain concise.
- **`MediaBadge` extensions:** Add image traits (`raw`, `livePhoto`, `portrait`, `transparent`, `animated`) while reusing `.hdr` (Display P3 / Gain Map HDR) and `.edited`.
- **Browser filtering (`LibraryBrowser`, `QualityFilter`):**
  - Add `mediaFilter: MediaKindFilter` (`all`, `videos`, `images`) powering the segmented header in `Photos` and `Files`.
  - Extend `QualityFilter` with megapixel resolution buckets (`48 MP+`, `24 MP+`, `12 MP+`, `< 12 MP`) and image trait filters while keeping existing video quality buckets cleanly grouped.
- **Photos support (`PhotoAsset`, `PhotoSubtypes`, `PhotoKitStore`, `PhotoSaver`):**
  - Fetch both `.video` and `.image` user-library assets in batches (`PhotoStore.assets()`), keeping cold-launch fetch fast (lightweight properties first; resource sizing without downloading iCloud originals).
  - Fetch & stage Live Photo `.pairedVideo` alongside the still photo in `Work/<job-id>/`.
  - Extend `PhotoSaver` with `saveImage` and `saveLivePhoto` (using `PHAssetCreationRequest`, `.photo` + `.pairedVideo`, copying `creationDate`, `location`, `isFavorite`, `isHidden`, `caption`, and `albums`), reading back and verifying pixel dimensions, non-empty resource size, date, location, albums, and Live Photo subtype before allowing `OriginalsDeleter`.

### 2. Image Engine & Metadata (`MediaEngine`)
- **`ImageSpec`:** Target sizing mode (`megapixels(Double)`, `scalePercent(Int)`, `maxPixels(Int)`, `customBounds(width: Int, height: Int)`, `keepOriginal`), never upscaling; `format` (`keepOriginal`, `heic`, `jpeg`, `png`, `avif`, `tiff`, `gif`); `quality` (`0.0...1.0`, default `0.80`); `isLossless: Bool`; `targetByteSize: Int64?`; `flattenAnimation: Bool`; `livePhotoMode` (`.preserve`, `.stillOnly`).
- **`ImageInspector`:** Decodes image properties via `CGImageSourceCopyPropertiesAtIndex` (zero full pixel decode during inspection) to produce `MetadataInventory` covering EXIF, TIFF, GPS, IPTC, XMP, MakerNote summary, ICC profile, HDR Gain Map presence, Depth/Matte presence, alpha flag, frame count, and RAW status.
- **`ImageConverter` (`@concurrent`, `WorkSlots`, `AtomicOutput`):**
  - Reads source with `CGImageSource` (or `CIRAWFilter` + `CIContext` for RAW/ProRAW into 16-bit half-float / Display P3 to preserve tone map & HDR).
  - Resizes accurately without upscaling; normalizes orientation upright (`kCGImagePropertyOrientation = 1`) while updating pixel X/Y dimensions and retaining all EXIF, TIFF, MakerNote, GPS, IPTC, XMP, and ICC profile dictionaries.
  - Preserves Gain Map auxiliary data (`kCGImageDestinationPreserveGainMap` / scaled Gain Map buffer) and Depth/Portrait matte auxiliary data (for HEIC) when encoding.
  - Copies multi-frame delays (`DelayTime`, `UnclampedDelayTime`, `LoopCount`) when preserving animated GIF / APNG / HEICS.
  - When `targetByteSize` is set, binary searches compression quality in temporary staging (and scales down cautiously only if minimum quality exceeds target) before atomically renaming final output with `AtomicOutput`.

### 3. Convert Tool, Runners, Loss Check, & Entry Points (`Convert`, `QuickRunService`)
- **Job kinds & compatibility:** Keep `"downscale-video"` and `"downscale-video-photos"` unchanged; add `"convert-image"`, `"convert-image-photos"`, and `"convert-live-photo"`. Add optional `imageSettings: ImageConvertSettings?` to `ConvertJobSettings` with safe backward-compatible decoding.
- **`ImageLossCheck`:** Predicts unavoidable format losses (RAW sensor data, alpha transparency when target is JPEG, animation frames when target is static, depth/matte when target is not HEIC, Live Photo motion when flattening) before queueing, and blocks silent metadata loss via `MetadataDiff` before Replace Original.
- **`ImageConvertRunner` & `PhotosImageConvertRunner`:**
  - Enforces `<10%` savings -> `"Kept as Is"` **only** when output format matches source format; format conversions save when valid even under 10%.
  - Live Photos in `.preserve` mode run `ImageConverter` on the still + `VideoDownscaler` on the paired `.mov` cleanly in parallel/sequence and commit them atomically via `PhotoSaver.saveLivePhoto`.
- **Overview, Assistant & Quick Run:**
  - Include image statistics in `OverviewSummary`, `OverviewCharts`, `SmartPicks`, `QueryTranslator` / `LibraryFilters`, `ShareExtension`, Mac Drag/Drop/Menu Bar/Dock/Finder Services, and App Shortcuts (`ShrinkMediaIntent` + backwards-compatible `ShrinkVideosIntent`).

### 4. macOS & iOS UI (`ConvertUI`, `Apps/macOS`, `Apps/iOS`)
- Top **All / Videos / Images** switcher on both `Photos` and `Local Files`.
- Updated Conversion Options (iOS) & Inspector (Mac) showing MP presets + scale `%` with live resulting dimensions & MB per row, Image More Options (Quality slider + guide, Format, Custom W × H, Target File Size, Live Photo mode), and stacked Video + Image sections on mixed bulk selection.
- Real thumbnails and interactive `CompareSheet` support for converted images; `IOSQueueJobEditor` supports editing queued image & Live Photo settings cleanly.
