# Real iPhone clips for the Dolby Vision gate

Aarik's first release depends on one question: does shrinking a 4K iPhone clip to 1080p keep genuine Dolby Vision
and the iPhone metadata? Synthetic clips can't answer that, so the gate needs a few short clips from a real iPhone.

## What to record

Put the clips in `Fixtures/iphone/` using exactly these names. Each should be 2 to 3 seconds long. Turn on Location
Services for the Camera app first (Settings > Privacy & Security > Location Services > Camera), so the clips carry
location metadata.

| File | What to record |
| --- | --- |
| `dv-4k60.mov` | Normal Video mode, 4K at 60 fps, HDR (Dolby Vision) on. |
| `dv-4k30.mov` | Normal Video mode, 4K at 30 fps, HDR (Dolby Vision) on. This one also checks the iPhone metadata. |
| `cinematic.mov` | Cinematic mode video (the one with the focus-change effect). |
| `spatial-audio.mov` | Normal video recorded with spatial audio (Audio Mix or Spatial Audio on, if your iPhone offers it). |
| `slomo.mov` | Slo-mo video (for example 1080p at 240 fps). |
| `live-photo.mov` | The video part of a Live Photo (see below on how to get it). |
| `sdr.mov` | A normal clip with HDR video turned off (Settings > Camera > Record Video > HDR Video off). |
| `spatial-video.mov` | Spatial Video (iPhone 15 Pro or later, Spatial Video on). Aarik should refuse this one. |

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
   cd Packages/AarikKit && swift test --filter RealClipGateTests
   ```

   Each test prints where it wrote its output file. The `cinematicReportsLosses` test also prints which metadata
   was lost, which goes into the decision record.

2. Check that every frame of each Dolby Vision output still carries Dolby Vision data. From the repo root, for
   each output from `dv-4k60` and `dv-4k30`:

   ```
   scripts/dv-check.sh <output>
   ```

   It must exit with success (status 0).

3. Manual check: open each Dolby Vision output in QuickTime Player, and import it into Photos. Both should show
   it as HDR / Dolby Vision, and it should look like the original. Tell Claude what you see.

The result is recorded in `docs/adr/0001-dolby-vision-downscale-route.md`.
