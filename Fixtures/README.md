# Real iPhone clips for the Dolby Vision gate

The app's first release depends on one question: does shrinking a 4K iPhone clip to 1080p keep genuine Dolby Vision
and the iPhone metadata? Synthetic clips can't answer that, so the gate needs a few short clips from a real iPhone.

## What to record

Put the clips in `Fixtures/iphone/` using exactly these names. Each should be 2 to 3 seconds long. Turn on Location
Services for the Camera app first (Settings > Privacy & Security > Location Services > Camera), so the clips carry
location metadata. The `dv-4k30` test fails if its clip has no location.

Record every clip in 4K wherever the camera mode allows it (Settings > Camera > Record Video > 4K). The two Dolby
Vision clips must be 4K; the tests fail otherwise. Some modes can't record 4K, and that's fine: Slo-mo is usually
1080p (4K only at 120 fps on recent Pro models), Cinematic is 1080p on older models, Spatial Video is 1080p, and a
Live Photo's video is smaller still. The tests shrink those clips to a size below their own (a short side of 720
pixels, or half the short side for clips that are 720 pixels or smaller), so none is skipped as "already small".

| File | What to record |
| --- | --- |
| `dv-4k60.mov` | Normal Video mode, 4K at 60 fps, HDR (Dolby Vision) on. |
| `dv-4k30.mov` | Normal Video mode, 4K at 30 fps, HDR (Dolby Vision) on. This one also checks the iPhone metadata. |
| `cinematic.mov` | Cinematic mode video (the one with the focus-change effect). |
| `spatial-audio.mov` | Normal video with spatial audio: Settings > Camera > Record Sound > Spatial Audio, where your iPhone offers it. |
| `slomo.mov` | Slo-mo video (for example 1080p at 240 fps). |
| `live-photo.mov` | The video part of a Live Photo (see below on how to get it). |
| `sdr.mov` | A normal clip with HDR video turned off (Settings > Camera > Record Video > HDR Video off). |
| `spatial-video.mov` | Spatial Video (iPhone 15 Pro or later, Spatial Video on). The app should refuse this one (see below). |

A spatial video stores two views, one per eye, in one track. The app's encoder writes a single view, so shrinking it
would silently drop one eye and leave a flat video. The app refuses spatial video instead, and the test checks that.

`Fixtures/iphone/` is git-ignored because the clips contain your location. They will never be committed. Don't
move them anywhere else in the repo.

## Getting the originals off the iPhone without re-encoding

The clips must be the untouched originals. Don't use a share sheet option that says "Optimize" or "Most Compatible".

- Photos on Mac: select the clip, then File > Export > Export Unmodified Original.
- AirDrop: on the iPhone choose the clip, tap Share > AirDrop, open Options at the top, and turn on All Photos Data.

For the Live Photo, export it the same way. The export gives you a photo and a `.mov` file; use the `.mov`.
Rename each file to the name in the table.

## Running the gate

1. Run the tests (tests whose clip is missing are skipped):

   ```
   cd Packages/AppModules && swift test --filter RealClipGateTests
   ```

   For the gate run itself, set `REAL_CLIP_GATE=1` so a missing clip fails instead of being skipped:

   ```
   cd Packages/AppModules && REAL_CLIP_GATE=1 swift test --filter RealClipGateTests
   ```

   Each test prints the path of its output file. Outputs are left in place, in a new `real-clip-gate-…` folder in the
   temporary folder, so you can check them in the next steps. The `cinematicReportsLosses` test also prints what
   was kept, changed and lost, which goes into the decision record.

2. Check that every frame of each Dolby Vision output still carries Dolby Vision data. From the repo root, for
   each output from `dv-4k60` and `dv-4k30`:

   ```
   scripts/dv-check.sh <output>
   ```

   It must exit with success (status 0).

3. Compare each Dolby Vision output's per-frame Dolby Vision data with its source, to see whether the camera's own
   data was kept or regenerated:

   ```
   scripts/dv-compare.sh Fixtures/iphone/dv-4k30.mov <output>
   ```

   Exit status 0 is PASS and 1 is FAIL. Status 3 (INCONCLUSIVE) means this ffprobe can't show the per-frame
   brightness and trim data, so only part of the comparison ran. Paste the output into the decision record either
   way.

4. Manual check: open each Dolby Vision output in QuickTime Player, and import it into Photos. Both should show
   it as HDR / Dolby Vision, and it should look like the original. Tell Claude what you see.

The result is recorded in `docs/adr/0001-dolby-vision-downscale-route.md`.
