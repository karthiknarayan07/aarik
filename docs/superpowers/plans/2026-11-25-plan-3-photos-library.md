# Plan 3 — Photos Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The user's Photos library (iCloud Photos) becomes a first-class source. The Videos grid comes from PhotoKit with a metadata-only scan, and the Overview dashboard shows what could be freed. Queued Photos videos are fetched in their current version (the edited version when edited), downloading from iCloud with progress and cancel. They are converted with the existing engine and saved back to Photos as new assets. Each new asset keeps date, location, favorite, hidden and albums. Replace saves and verifies the new asset, optionally backs up the original, then moves the originals to Recently Deleted, with one system confirmation per batch.

**Architecture:**
- **New package target `PhotosLibrary`** (→ `MediaEngine`, `AppCore`). It wraps PhotoKit behind a `PhotoStore` protocol: one real `PhotoKitStore` and one `FakePhotoStore` for tests, so no test touches the real library.
- **Grid items carry a source:** `LibraryItem` gains `source: ItemSource` (`.file(URL)` / `.photos(localIdentifier)`). The grid, browser, presets, estimates and inspector are shared. `LibraryBrowser` reads from a `MediaCollection` protocol that both `LocalLibrary` and `PhotosLibrary` conform to.
- **Photos jobs** use a source URL of the form `x-photos-asset:<localIdentifier>` with an empty bookmark and their own tool ID. `PhotosDownscaleRunner` fetches the input to a work folder, reuses the existing downscale-and-verify core, saves the result to Photos, and verifies the new asset.
- **Replace in Photos** finishes a job as "replaced, original pending deletion". The app then deletes all pending originals of a run in one `performChanges` call, which is one system confirmation.

**Tech Stack:** Swift 6.4, PhotoKit (`PHPhotoLibrary`, `PHAsset`, `PHAssetResource`, `PHAssetResourceManager`, `PHAssetCreationRequest`, `PHAssetCollectionChangeRequest`, `PHCachingImageManager`, `PHPhotoLibraryChangeObserver`), SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-25-aarik-design.md`: §8.1 (Photos inputs, edited version, iCloud-only, special formats), §8.3 (Photos metadata on save), §8.3a (edited-DV exception), §8.5 (Photos Replace, originals backup), §9 (Overview, Videos), §10a item 3.


### Owner decisions (2026-11-25, after the plan was drafted)
- **Frame rate / codec / bit rate for Photos videos come from Photos' own index** (`Photos.sqlite`, tables `ZASSET` + `ZEXTENDEDATTRIBUTES`: `ZFPS`, `ZCODEC`, `ZBITRATE`, `ZDURATION`; `ZASSET.ZHDRTYPE`), read **read-only** after a one-time **Full Disk Access** grant the app asks for with plain copy. Unofficial source: open a private snapshot (copy `Photos.sqlite` + `-wal` + `-shm` to a temp folder, then open `?mode=ro`), never write, tolerate missing columns/tables, and fall back to "fps unknown" (PhotoKit-only data) when it can't be read. Matched to PhotoKit assets by `ZASSET.ZUUID` = the UUID prefix of `localIdentifier`.
- **Never download originals to browse.** Listing, badges, filters, thumbnails and preview use metadata, the index and Photos' local thumbnails/streaming preview only. Originals are downloaded only when a queued job runs.
- **Quality filters (both Photos and Local Files):** resolution + frame-rate chips (4K60, 4K30, 4K24, 1080p60, 1080p30, 720p, Other, Unknown), file size (e.g. > 100 MB, > 500 MB, > 1 GB) and duration ranges, codec (HEVC / H.264 / ProRes / Other) and dynamic range (Dolby Vision / HDR / SDR). Combined with AND with the existing media-type filters; the "Could free about X" header follows the filtered set.

## Global Constraints

- Everything from Plan 2's Global Constraints still holds. In particular:
  - brand-neutral code
  - macOS 26, arm64
  - Swift 6 strict concurrency, zero warnings, `swift format lint` clean
  - no third-party dependencies, no networking APIs of our own (PhotoKit's iCloud download is allowed, §12)
  - system UI only
- **The user's Photos library is never modified except:**
  - (a) adding the converted asset
  - (b) adding that asset to the same albums as the source
  - (c) for Replace only, deleting the original via `PHAssetChangeRequest.deleteAssets`, which moves it to Recently Deleted and always shows the system confirmation. This happens only after the new asset is saved and verified.
  - Never edit an existing asset's content; never use revertible edits (they save no space, §8.5).
- **Tests never touch the real Photos library.** Unit and integration tests use `FakePhotoStore`. Real-library checks are manual and done by the controller in the running app. They write to Photos only with the owner's go-ahead, and only on test assets created for the purpose.
- **Scanning is metadata-only (§10a):** listing the library never downloads from iCloud. Downloads happen only for queued jobs (and for an explicit inspector "Check details" action, if built).
- Info.plist: `NSPhotoLibraryUsageDescription` (plain sentence, brand from the bundle).
- Edited videos: input is Photos' rendering of the current version (§8.1). Unedited: the original resource.
- Special formats (§8.1):
  - Spatial video is refused with the existing `DownscalePlanner.spatialReason` (Kept As Is); Photos' `spatialMedia` subtype refuses before any download.
  - Slo-mo frame rate stays locked, as today.
  - The Live Photo pairing ID is kept on export only.

## Review Focus

1. **iCloud-only original, offline or download cancelled:**
   - The job fails with "Couldn't download from iCloud" (or is cancelled).
   - No partial files are left in the work folder.
   - The source asset is untouched, and Retry works.
2. **The user deletes or edits the asset in Photos while it is queued:**
   - Deleted → the job fails with "No longer in your Photos library".
   - Edited after queuing → the job uses the version current at run time.
3. **Save-to-Photos fails or the new asset doesn't verify:**
   - The original is never deleted.
   - A half-made new asset is removed where PhotoKit allows it; otherwise it is reported.
4. **Replace batch where the user cancels the system delete confirmation:**
   - The new assets stay.
   - The jobs show "Original kept — you cancelled deletion".
   - The pending deletions can be retried from the UI, and nothing is deleted silently later.
5. **Large library (thousands of videos):**
   - The grid appears fast, thumbnails are cached, and scrolling is smooth.
   - Change observation applies incremental updates, not full rescans.

---

## File Structure

```
Packages/AppModules/Sources/PhotosLibrary/
  PhotoStore.swift            protocol PhotoStore + value types (PhotoAsset, PhotoAlbum, PhotoSaveRequest, errors)
  PhotoKitStore.swift         real implementation (authorization, fetch, resources, download, save, delete, observe)
  FakePhotoStore.swift        in-memory implementation for tests (public, used by app previews/tests)
  PhotosLibrary.swift         @MainActor @Observable facade: authorization state, items, revision, refresh on changes
  PhotoItemBuilder.swift      PhotoAsset → LibraryItem (badges from subtypes, size from resources)
  PhotoInputFetcher.swift     fetch current version to a work folder with progress/cancel
  PhotoSaver.swift            save converted file as new asset + copy date/location/favorite/hidden/albums; verify
  PendingDeletions.swift      persisted list of original asset ids awaiting the batch delete
Packages/AppModules/Sources/LocalLibrary/
  ItemSource.swift            enum ItemSource { file(URL), photos(String) }
  MediaCollection.swift       protocol the browser reads (items, revision)
Packages/AppModules/Sources/DownscaleVideo/
  PhotosDownscaleRunner.swift JobRunner for Photos jobs
  PhotosJobFactory.swift      selection of Photos items → jobs
App/Sources/
  PhotosView.swift            Videos page (authorization states, grid)
  OverviewView.swift          savings dashboard
  PendingDeletionBar.swift    "Move N originals to Recently Deleted" + explanation of iCloud space timing
Tests/PhotosLibraryTests/…    store fake, builder, fetcher, saver, pending deletions
Tests/DownscaleVideoTests/PhotosRunnerTests.swift
```

Dependency rule: `PhotosLibrary` → `MediaEngine`, `AppCore`, `LocalLibrary` (for `LibraryItem`/`ItemSource`/`MediaCollection`). `DownscaleVideo` → `PhotosLibrary` is allowed only for the runner/factory files. The App imports everything.

---

### Task 1: PhotoKit spike in the running app (go/no-go facts)

**Purpose:** settle on the owner's real library, before building on them, the facts the rest of the plan depends on.

**Files:**
- `App/Sources/Debug/PhotosSpikeView.swift` (DEBUG-only menu item "Debug ▸ Photos spike…"). This file is deleted in Task 8.
- `docs/adr/0002-photos-input-and-save.md` (findings).

- [ ] Request `.readWrite` authorization, fetch video assets, and print:
  - count
  - `mediaSubtypes` distribution
  - how many have `hasAdjustments`
  - how many resources are local vs cloud: `PHAssetResource` `locallyAvailable`, reached via KVC on `value(forKey:)`, wrapped so a missing key gives "unknown"
  - file sizes: KVC `fileSize`, with the same fallback
- [ ] For one unedited DV clip, write `.video` with `PHAssetResourceManager.writeData(…, options.isNetworkAccessAllowed = true)` and run `MetadataReader` on it. **Expect:** identical to "Export Unmodified Original" (DV, location, make/model).
- [ ] For one edited clip, write `.fullSizeVideo` if present. Otherwise use `PHImageManager.requestExportSession(forVideo:options:exportPreset: AVAssetExportPresetPassthrough)` with `version = .current`, and record which path works. Inventory it and note what survives (DV? location? creation date?). The result decides the edited-DV wording (§8.3a exception).
- [ ] Owner go-ahead required for this step: save a small test clip to Photos via `PHAssetCreationRequest` with:
  - `creationDate`
  - `location`
  - `isFavorite = true`
  - `isHidden = false`
  - adding it to a temporary album "aarik test"
  Then:
  - Re-fetch it and confirm the values.
  - Write its `.video` back out and confirm DV and metadata survived Photos' import.
  - Delete it, together with the test album, via `deleteAssets`. **Expect:** the system confirmation appears, and the asset is in Recently Deleted afterwards.
- [ ] Record all findings and the chosen APIs in ADR 0002. If any fact contradicts this plan, amend the later tasks before dispatching them.

### Task 2: `PhotosLibrary` target — store protocol, fake, real store (read side)

**Interfaces (Produces):**
```swift
public struct PhotoAsset: Sendable, Hashable, Identifiable {
    public let id: String                 // localIdentifier
    public let creationDate: Date?
    public let location: PhotoLocation?   // lat, lon, altitude
    public let pixelSize: CGSize          // as displayed
    public let duration: Double
    public let isFavorite: Bool
    public let isHidden: Bool
    public let hasAdjustments: Bool
    public let subtypes: PhotoSubtypes    // OptionSet: highFrameRate, cinematic, spatial, timelapse, streamed
    public let originalFileName: String
    public let originalByteSize: Int64?   // nil when unknown
    public let isLocallyAvailable: Bool?  // nil when unknown
}
public enum PhotoAuthorization: Sendable { case notDetermined, denied, restricted, limited, authorized }
public protocol PhotoStore: Sendable {
    func authorization() async -> PhotoAuthorization
    func requestAuthorization() async -> PhotoAuthorization
    func videos() async throws -> [PhotoAsset]
    func changes() -> AsyncStream<Void>        // library changed; callers refetch (diffing is the facade's job)
    func albums(containing id: String) async throws -> [String] // album localIdentifiers (user albums only)
    func thumbnail(for id: String, size: CGSize) async -> CGImage?
}
```
- Tests (`FakePhotoStore`):
  - `PhotoItemBuilder` maps subtypes to badges: cinematic → `.cinematic`, highFrameRate → `.sloMo`, spatial → `.spatial`, hasAdjustments → `.edited`, ≥ 3840×2160 → `.k4`.
  - The item's `source == .photos(id)` and `byteSize == originalByteSize ?? 0`.
- `PhotoKitStore.videos()`:
  - one `fetchAssets(with: .video)` with only the needed sort descriptors
  - resource sizes read lazily in a background task, in batches
  - must not block the main actor
  - must not download

### Task 3: Shared grid over a `MediaCollection`; `LibraryItem.source`

- `ItemSource`; `LibraryItem` gains `source`. Keep `url` working for `.file` items through a computed `fileURL: URL?`, and migrate call sites.
- `MediaCollection` protocol (MainActor): `items`, `revision`, `isScanning`. `LibraryBrowser` is initialised with any `MediaCollection`.
- `PhotosLibrary` (`@MainActor @Observable`, conforms to `MediaCollection`):
  - authorization state
  - first load
  - refetch on `changes()`, coalesced to at most one refetch in flight
  - stable item ids derived from the localIdentifier (UUID v5-style hash, or keep `String` ids; the implementer chooses and documents the choice)
- App:
  - The sidebar "Videos" item is enabled.
  - `PhotosView` shows: authorization prompt (with one sentence of trust copy), denied state (button to open System Settings ▸ Privacy ▸ Photos), limited state note, then the same grid/inspector as Local Files with its own `LibraryBrowser`.
  - Thumbnails go through `PhotoStore.thumbnail`, cached in `ThumbnailCache` by key.
- Tests:
  - the browser works with a fake collection
  - local-file behaviour is unchanged (existing tests pass)

### Task 4: Fetching input — current version, iCloud download, progress, cancel

`PhotoInputFetcher.fetch(id:into workFolder:progress:) async throws -> FetchedInput`:
- `FetchedInput` holds `url`, `isEditedVersion`, `bytes`.
- Uses the API settled in Task 1.
- Writes into `<Application Support>/<bundle id>/Work/<job id>/`. The folder is created per job and removed by the runner on every exit path. Stale `Work/*` is swept at launch.
- Errors:
  - `.notInLibrary`
  - `.downloadFailed(underlying)`: the message mentions iCloud and being online
  - `.cancelled`
- Tests (fake store):
  - progress forwarded
  - cancellation removes the partial file
  - deleted asset → `.notInLibrary`

### Task 5: Saving to Photos — new asset with date, location, favorite, hidden, albums; verify

`PhotoSaver.save(file:like source: PhotoAsset, albums: [String]) async throws -> String`, which returns the new localIdentifier:
- One `performChanges` call.
- Creation request from the file, using `.video` with `shouldMoveFile = false`.
- Sets `creationDate`, `location`, `isFavorite`, `isHidden`, and adds the asset to each album (skipping albums that no longer exist).
- Verify:
  - re-fetch the new asset by id
  - duration within 0.1 s of the source
  - pixel size matches the plan's target
  - the resource file size is > 0
- On a verify failure, attempt to delete the new asset. This shows the system confirmation; if the user declines, report it.
- Tests: the fake store records requests; the saver passes the copied fields; album filtering; verify-failure path.

### Task 6: `PhotosDownscaleRunner` + job factory + save destinations for Photos

- Tool ID `DownscaleTool.photosToolID`. The source URL is `x-photos-asset:<id>`.
- Settings: same `DownscaleJobSettings`, plus `photosDestination`:
  - `.newAsset` (default, §12)
  - `.replace`
  - `.folder(URL)`: the file goes to the folder with the normal naming
- Run steps:
  1. Fetch the input (progress phase "Downloading from iCloud" maps to the first 0–20 % of progress when a download happens).
  2. Plan: re-check Kept As Is with the real inventory. Spatial is refused.
  3. Downscale to the work folder (existing engine + verify gate) and apply the R12 size check.
  4. Save according to the destination.
  5. For `.replace`: if originals backup is on, copy the fetched input to the backup folder using `OriginalsBackup` (edited-version inputs back up the original resource via a second fetch of `.video`). Then record the original id in `PendingDeletions` and finish with outcome note "Original will move to Recently Deleted".
  6. Remove the work folder.
- `JobOutcome` for Photos:
  - `output` = `x-photos-asset:<newId>`
  - `replacedOriginal` stays false until the batch delete succeeds; the app then updates the outcome via a queue API (`JobQueue.updateOutcome(id:transform:)`)
- Tests with the fake store and a fixture clip:
  - newAsset path
  - replace path records a pending deletion
  - spatial refused
  - offline download failure → failed job, no new asset
  - verify failure → original untouched, no pending deletion

### Task 7: Batch delete of originals, pending-deletion UI, Overview

- `PendingDeletions`:
  - persisted JSON
  - `add`, `all`, `remove`
  - survives relaunch
- After a queue run finishes, or when the user clicks the bar, the app calls `PhotoStore.deleteAssets(ids)` once.
  - On success: mark those jobs replaced, show the saved total, and reconcile the grid (the old item disappears through change observation).
  - On user cancel: keep the pending list, and the bar says "Originals kept. You can move them to Recently Deleted later."
- `PendingDeletionBar` copy says plainly that iCloud space is freed when Recently Deleted is emptied or after 30 days.
- `OverviewView`:
  - totals for Videos and for Local Files: count, size, and "could free about X" at the current preset
  - biggest savings first (top 10, click → select in its grid)
  - space saved so far (sum of completed outcomes)
- Tests: pending-deletions persistence; outcome update API; overview math on fakes.

### Task 7a: Photos index reader (frame rate, codec, bit rate, HDR)

`PhotosIndex` (in `PhotosLibrary`): `func load() async -> [String: PhotoIndexEntry]` keyed by asset UUID, `PhotoIndexEntry { fps: Double?, codec: String?, bitRate: Double?, hdrType: Int? }`. Snapshot-copy then read-only open, column-existence checks via `pragma table_info`, returns `[:]` with a reason (`.noAccess` / `.unreadable`) instead of throwing. Settings + Videos page: "Allow access to frame rates" row explaining Full Disk Access with a button that opens System Settings ▸ Privacy & Security ▸ Full Disk Access. `PhotoItemBuilder` uses the entry for `frameRate` and DV/HDR/SDR badges. Tests use a small generated SQLite fixture with the same columns (and one with a column missing).

### Task 7b: Quality filters for both libraries

`QualityFilter` (value type, in `LocalLibrary` next to grouping/sort): resolution-fps buckets, size range, duration range, codec set, dynamic range set; `matches(LibraryItem) -> Bool`; buckets derived from pixel size short side (≥2160 → 4K, ≥1080 → 1080p, ≥720 → 720p, else Other) and frame rate rounded (≥100 → 120+, ≥50 → 60, ≥28 → 30, ≥24.5 → 25, ≥23 → 24), unknown fps → "Unknown". `LibraryBrowser` applies it with the badge filter; the header and counts follow. UI: a filter bar (system `Menu`s / tokens) above the grid showing only buckets present in the current collection with counts. Tests: bucket math, AND combination, header totals follow the filter.

### Task 8: Polish, accessibility, cleanup, docs

- Remove the spike view.
- VoiceOver labels on all new controls.
- Empty, denied and limited states.
- Keyboard parity with Local Files.
- README section on the Photos permission and iCloud space timing.
- ADR 0002 final.
- The full test suite and lint pass.

## Rulings during execution
- Ruling (2026-11-25): the Photos index can't tell Dolby Vision from other HDR (videos only carry ZHDRTYPE 0 or 5).
  When wiring Task 3, an HDR (type 5) video whose camera make is Apple (ZEXTENDEDATTRIBUTES.ZCAMERAMAKE, if present) is badged
  `.dolbyVision` — iPhone HDR video is Dolby Vision 8.4 — otherwise `.hdr`. The real inventory at queue time is authoritative.
  Cost if wrong: a non-DV Apple HDR clip shows a DV badge in the grid until inspected.
- The Photos index has no bit rates in this library (ZBITRATE empty); estimates keep using size ÷ duration.
