# ADR 0002: Photos input and save

Status: **Accepted** (spike run on the owner's real library, macOS 27.2.1, Apple silicon)

## Context

Plan 3 builds the Photos features (list, fetch, shrink, save back, delete the original) on PhotoKit. Before building,
a DEBUG-only spike (`-photosSpike` launch argument, `App/Sources/Debug/PhotosSpike*.swift`, removed in Plan 3 Task 8)
ran every risky step once against the real library and logged each fact. This ADR records the numbers, the APIs
chosen, and what they change in the plan. Personal clip names, locations and dates are not recorded here, only
counts and technical facts.

The library was only read, apart from two small temporary files and one generated test asset (see "Save round
trip"). The test asset and its temporary album were deleted again.

## Facts from the library survey

1,602 videos in the user library (hidden videos: none, the count is the same with and without them). Reading the
metadata and resource list of all 1,602 assets took 5.9 s (about 3.7 ms per asset) and downloaded nothing.

| Fact | Result |
| --- | --- |
| Subtypes | high frame rate 8, cinematic 31, time-lapse 1, spatial 0, streamed 0, none of these 1,562 |
| `hasAdjustments` (edited) | 67 of 1,602 |
| Edited with a `.fullSizeVideo` resource | 63 of 67 (the other 4 have only `.video` + `.adjustmentData`) |
| Edited with `.fullSizeVideo` on this Mac | 0 of 63 |
| `.video` on this Mac vs iCloud only | 8 local, 1,594 iCloud only, 0 unknown |
| Local split | 4 unedited, 4 edited |
| Size known (`dataSize`) | 1,602 of 1,602 |
| Size, all videos | total 61,548 MB; min under 1 MB; median 14 MB; p90 80 MB; max 3,104 MB |
| Size, local vs iCloud only | local 142 MB; iCloud only 61,405 MB |
| Size bands | 1,478 under 100 MB; 2 at 1 GB or more |
| Resource shapes | `video` 1,532; `video+adjustmentData+type16+fullSizeVideo` 39; `video+adjustmentData+fullSizePhoto+fullSizeVideo` 18; `video+adjustmentData+type16+fullSizePhoto+fullSizeVideo` 5; `video+adjustmentData` 4; `video+type16` 3; `video+adjustmentData+fullSizeVideo` 1 |

Notes:

- The library is stored the "optimized" way: 99.5 % of the videos (99.8 % of the bytes) are in iCloud only. Almost
  every job will start with a download.
- `PHAssetResource.dataSize` (public on macOS 27) answered for every resource, and the KVC read of `locallyAvailable`
  answered for every resource ("unknown" never happened). The existing `PhotoKitStore` code is right as it stands.
- Resource type raw value 16 has no public name in this SDK. It appears on 47 assets and is harmless; the store should
  not treat an unknown type as an error.
- A newly saved asset reports a media subtype bit (`1 << 20`) that the SDK headers do not name. Subtype tests must be
  "contains a known flag", never equality with `[]`.

## Unedited clip: write the `.video` resource

`PHAssetResourceManager.writeData(for:toFile:options:)` with `isNetworkAccessAllowed = true` on the `.video`
resource of an unedited, local clip (28.7 MB, 15.4 s, iPhone 14 Pro Max) wrote the file in under 0.1 s. Inventory
(the app's own metadata reader) found:

- Dolby Vision profile 8, level 5, compat 4; HEVC `hvc1`, 10-bit, BT.2020 / HLG, 1080p, 59.94 fps
- location present; make and model present (Apple, iPhone 14 Pro Max); software and creation date present
- ambient viewing environment, lens metadata, and 9 timed-metadata tracks (orientation, faces, live-photo-info,
  scene illuminance, segment identifier)

So the `.video` resource is the original file as the camera wrote it: this is the same as "Export Unmodified
Original" in Photos, as expected. Chosen API for unedited clips.

Download speed measured on iCloud-only clips (the same two resources as below): 44.7 MB in 26.9 s and 54.9 MB in
29.2 s, about 1.7 MB/s on this network. A 3 GB clip would take about 30 minutes, so download progress, cancel and a
separate "Downloading from iCloud" phase are not optional.

## Edited clip: use the export session, version `.current`

Two edited clips were checked.

**A. Edited, rendering not on this Mac, and no `.fullSizeVideo` at all** (resources `video` + `adjustmentData`;
SDR 8-bit 1080p 30 fps, 2.8 s, iPhone 13). `.fullSizeVideo` does not exist for this shape, so writing it is not an
option. `PHImageManager.requestExportSession(forVideo:options:exportPreset: AVAssetExportPresetPassthrough)` with
`version = .current` returned a session at once; `export(to:as: .mov)` took 0.1 s and wrote 4.1 MB. All inventoried
metadata matched the original `.video` (location, make, model, software, creation date, dimensions, frame rate,
transform, color tags, audio); only the file creation date differs.

**B. Edited, with a cloud-only `.fullSizeVideo`** (resources `video` + `adjustmentData` + `fullSizePhoto` +
`fullSizeVideo`; HEVC 10-bit HLG 1080p 59.77 fps, 21.3 s, iPhone 14 Pro Max, 44.7 MB original, 54.9 MB rendering).

- Export session with `isNetworkAccessAllowed = false`: no session; the info dictionary has `PHImageResultIsInCloudKey`
  = true and the error is `PHPhotosErrorDomain` code 3164 (network access required). Nothing was downloaded. This
  is the "Couldn't download from iCloud" signal.
- Writing `.fullSizeVideo` with network access downloaded 54.9 MB in 29.2 s.
- Export session with network access afterwards: 0.3 s, 54,861,593 bytes, which is the rendering again (within 12
  bytes of the `.fullSizeVideo` file, so the passthrough export is a re-wrap of the stored rendering, not a
  re-encode). Its inventory is identical to the `.fullSizeVideo` inventory.
- `.video` (the original) to the current rendering:
  - **Kept:** Dolby Vision (profile 8, compat 4; level 5 became 6), location, make, model, software, creation date,
    ambient viewing environment, dimensions, frame rate, transform, color tags, audio, 6 of 7 timed-metadata tracks.
  - **Changed:** duration 21,298 ms to 21,300 ms.
  - **Lost:** the `live-photo-info` timed-metadata track.

Result: both ways work, but the export session is the one API that works for both shapes (with and without a
`.fullSizeVideo`), is gated cleanly by `isNetworkAccessAllowed`, and in the `.fullSizeVideo` case it is a cheap
re-wrap. Chosen API for edited clips: `requestExportSession(version: .current, preset: passthrough)`, output `.mov`.
Writing `.fullSizeVideo` directly stays a fallback, not the plan.

Edited Dolby Vision (§8.3a exception): the one DV edit that was checked kept genuine Dolby Vision in Photos' current
rendering, plus location, make/model and creation date. The wording "edited clips may lose Dolby Vision" is therefore
not backed by evidence for edits that have a `.fullSizeVideo`. The case with no `.fullSizeVideo` (4 of 67 edited
clips here) was only seen on an SDR clip, so edited DV without a stored rendering remains unobserved. The job's
real inventory check (Plan 3 Task 6, step 2) already decides per clip, so no special wording is needed in the
app, only the generic "metadata changed" report.

## Save round trip

A generated clip (devtool, 1080p, 4.0 s, HEVC 10-bit HLG, Dolby Vision profile 8 level 4 compat 4, make
`TestMake`, model `TestModel`, with location and creation-date metadata in the file) was saved in one
`performChanges` call:

- `PHAssetCreationRequest.forAsset()`, `.video` resource from the file with `shouldMoveFile = false`
- `creationDate`, `location`, `isFavorite = true`, `isHidden = false`
- a new album created in the same change with the new asset added through its placeholder

Results:

- The change completed in 0.3 s. Adding an asset needs no confirmation (the owner mentioned an album-related prompt;
  it did not delay the call).
- Re-fetch by the placeholder's `localIdentifier` worked at once: media type video, 1920x1080, duration 4.0 s,
  `hasAdjustments` false, user-library source. `creationDate` equal to the value set, location equal (within 1e-4
  degrees), `isFavorite` true, `isHidden` false. The album held exactly 1 asset and contained the new one.
- The asset's resources: `video` only.
- Writing its `.video` back out gave a file of 820,655 bytes, the same size as the generated file. Metadata diff:
  23 items kept, 0 changed, 0 lost. Dolby Vision, make, model, software, location and creation date all survived
  Photos' import untouched. Photos does not transcode on import.

## Delete

`PHAssetChangeRequest.deleteAssets` inside `performChanges`:

- The **system confirmation appeared** (the owner clicked it); the call returned after 8.0 s, including the human
  wait. A declined dialog surfaces as an error from `performChanges` (the spike did not test a decline).
- Afterwards `PHAsset.fetchAssets(withLocalIdentifiers:)` finds **0** assets for the id. A trashed asset is not
  fetchable.
- The asset is in Recently Deleted: Photos' own database lists it with the trashed flag set, with the right
  size (1920x1080, 4.0 s, favorite). PhotoKit does not expose this: no smart album or collection for Recently Deleted
  is visible (24 smart albums were listed, none of them is Recently Deleted), and the `trashedState` key is not
  readable through KVC. The app cannot verify "moved to Recently Deleted" through PhotoKit; "fetch returns nothing
  after a successful delete" is the only signal.
- Deleting the temporary album (`PHAssetCollectionChangeRequest.deleteAssetCollections`) succeeded in 3.0 s. The owner
  reported clicking Allow on prompts for album creation and deletion as well as the asset delete; the log timings
  (0.3 s for the create-and-save change, 3.0 s for the album delete) suggest the album ones were quick, so budget
  for a possible prompt on album changes but do not rely on it. The album was confirmed gone afterwards.

## Decisions

1. Unedited clip: `PHAssetResourceManager.writeData` of the `.video` resource, network allowed only inside a queued
   job.
2. Edited clip: `PHImageManager.requestExportSession(forVideo:options:exportPreset:)` with `version = .current`,
   `AVAssetExportPresetPassthrough`, `.mov`. The first attempt of a job uses `isNetworkAccessAllowed = true`
   (a download is expected); error 3164 with `isNetworkAccessAllowed = false` is how the app knows an iCloud
   download is needed without starting one.
3. `isEditedVersion` is `hasAdjustments`. Edit-derived input is backed up by also writing the `.video` resource.
4. Saving: one `performChanges` with a creation request (`.video`, `shouldMoveFile = false`), `creationDate`,
   `location`, `isFavorite`, `isHidden`, and album adds, as in Plan 3 Task 5.
5. Deleting: `deleteAssets`; success is "the system dialog was accepted and the id no longer fetches".

## Plan amendments

These contradict or sharpen Tasks 4 to 8 of Plan 3.

- **Task 4 (fetching input):** "uses the API settled in Task 1" now means: unedited resolves to `writeData(.video)`,
  edited resolves to `requestExportSession` (not `.fullSizeVideo`, which does not exist for 4 of 67 edited clips and
  is not on this Mac for any of them). Map error 3164 / `PHImageResultIsInCloudKey` to `.downloadFailed` when the
  download was refused or failed. The export-session path writes into the job's work folder through
  `export(to:as:)`, so the "no partial files" rule applies to the export too (remove the output on failure and on
  cancel). Handle unknown resource types (raw 16) without error.
- **Task 4/6 (progress):** the plan maps the iCloud download to the first 0 to 20 % of job progress. With 99.5 %
  of videos in iCloud only and about 1.7 MB/s measured, the download is usually the longest phase (a 55 MB clip took
  29 s to fetch and 0.3 s to export). Show "Downloading from iCloud" as its own phase with its own progress and
  cancel, not a 20 % slice; time estimates for Photos jobs must include it.
- **Task 5 (saving):** works as planned in one `performChanges` including album adds through the placeholder; no
  dialog. Two corrections: (a) the planned "On a verify failure, attempt to delete the new asset" always shows the
  system confirmation, and a deleted asset can no longer be fetched, so after a delete the saver must not re-fetch
  to check; (b) a new asset carries an unnamed media-subtype bit, so verification must not compare subtypes for
  equality. Duration, pixel size and creation date/location checks are confirmed to work.
- **Task 6 (runner):** step 5's "edited-version inputs back up the original resource via a second fetch of `.video`"
  is confirmed to work (44.7 MB downloaded on its own). Photos' rendering of an edit can drop the live-photo-info
  timed-metadata track and shift duration by about 2 ms, so the real-inventory check must not call that a verify
  failure.
- **Task 7 (batch delete):** the system confirmation is confirmed. The "reconcile the grid" and the
  "moved to Recently Deleted" claim can only rest on the delete call succeeding and the id no longer fetching;
  PhotoKit cannot list Recently Deleted. The PendingDeletionBar copy must not promise a check the app cannot do.
  The cancel path (dialog declined) was not exercised in the spike and still needs a manual check in Task 7.
- **Task 7a/7b:** unaffected. For 7b the sample shows the real library's mix (8 high frame rate, 31 cinematic, 0
  spatial, 1 time-lapse), so the "Unknown fps" bucket matters until the index read exists.
- **Task 8 (cleanup):** remove `App/Sources/Debug/` (four files), the `AppDelegate` `#if DEBUG` hook, and decide
  whether to keep the devtool `fixture --seconds --size --camera-metadata` options (harmless, useful for manual
  Photos checks). `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` was added to `Config/App.xcconfig` for the spike and
  stays.
- **Global constraint (never modify except...):** held. The only library writes were one generated test asset and its
  temporary album, both removed (the asset sits in Recently Deleted until Photos empties it, up to 30 days).
