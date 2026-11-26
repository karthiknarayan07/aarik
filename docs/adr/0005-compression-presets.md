# ADR 0005: Compression presets

Status: **Accepted** (2026-11-26). Implemented in `Convert` (`CompressPreset`, `ConvertJobKind`) and `MediaEngine` (`DownscaleSpec.maxBitRate`, `VideoEncoder` `kVTCompressionPropertyKey_DataRateLimits`).

## Context

Plan 10 Task 5 adds a Convert job kind, `.compress(CompressPreset)`, with presets Smaller, Balanced and Best Quality.
Compression keeps the resolution, the frame rate, HDR and Dolby Vision handling (ADR 0001), and all metadata. Only
the HEVC bitrate changes. The design says the exact ratios are the builder's call, recorded here, and checked by the
existing quality checks and fixtures.

## Decision

Each preset is a **target video bitrate expressed as a ratio of the source's video bitrate**, applied to the HEVC
re-encode. Audio is passed through untouched.

| Preset | Target / source video bitrate | Intent |
|---|---|---|
| Smaller | 0.25 | Largest saving. Fine detail may soften. For sharing and archives. |
| Balanced (default) | 0.40 | Visually close on a phone and a laptop. Roughly 2.5x smaller. |
| Best Quality | 0.60 | Hard to tell from the source. About 40 percent saving. |

Rules around the ratio:

- Set `kVTCompressionPropertyKey_AverageBitRate` to the target (`CompressPreset.spec(for:)`). Also set
  `kVTCompressionPropertyKey_DataRateLimits` via `DownscaleSpec.maxBitRate = target * 2` (`[target * 2 / 8, 1.0]`
  bytes over a 1-second window, marked optional for encoders that reject it) to stop spikes. Apple's header says
  `AverageBitRate` is a soft limit and `DataRateLimits` is a hard cap, and they are meant to be used together.
- **Never exceed the source bitrate.** If the source video bit rate is at or below the floor (`ConvertPlanner.decide`),
  report "Already small" (`.keptAsIs(..., code: .alreadySmall)`) and leave the original untouched rather than
  inflating it; if an encode saves under 10%, `ConvertRunner` discards the output and keeps the original as
  `.savesLittle`.
- **Floor** per pixel rate so a low-bitrate source is not crushed: `0.04` bits per pixel per frame
  (`CompressPreset.minimumBitsPerPixel`), using `effectiveFPS = fps > 30 ? 30 + (min(fps, 60) - 30) * 0.5 : fps` and
  a `1_000_000` bps minimum (`2_000_000` bps when dimensions are unknown). Validated numbers:
  - 4K30 (`3840x2160` @ 30 fps): `9,953,280` bps (~10.0 Mbps)
  - 4K60 (`3840x2160` @ 60 fps): `14,929,920` bps (~14.9 Mbps)
  - 1080p30 (`1920x1080` @ 30 fps): `2,488,320` bps (~2.5 Mbps)
- Keep resolution and fps exactly (`targetShortSide = nil`, `maxFrameRate = nil`). Keep the codec HEVC
  (`.hevcKeepHDR`) and the same profile: Main for 8-bit, Main10 for 10-bit and HDR. Dolby Vision profile 8.4 sources
  keep the ADR 0001 route; the RPU survives. A preset must never be allowed to drop HDR or DV.
- Estimate the saving before running through `Estimator.estimatedBytes` (which yields roughly `(1 - ratio) x video bytes`
  above the floor, minus the 1% container allowance), and show it in the Compress picker (`CompressSheet`).

## Rationale

- iPhone capture bitrates are high so that the camera can encode in real time on a small chip. A 4K30 HEVC clip is roughly
  40 to 60 Mbps, and 4K60 HDR or Dolby Vision is often higher. An offline, multi-pass-capable re-encode is more
  efficient than the real-time capture encoder, so a large reduction is possible at the same visual quality.
- HEVC is generally quoted as needing about half the bitrate of H.264 for similar quality. Apple's HLS authoring
  guidance for HEVC ladders puts 4K and 1080p tiers far below iPhone capture rates (single-digit to low-tens of Mbps).
  Those delivery tiers are the reason Smaller at 0.25 is plausible for sharing. (Numbers recalled from memory; confirm
  against the current HLS Authoring Specification before finalising.)
- Ratios of the source are easy to explain in the UI and scale across 1080p, 4K, 30 and 60 fps without a lookup table.
  A fixed bitrate would over-compress a 4K60 clip and under-compress a 1080p30 one.
- Re-encoding is generation loss. The Best Quality ratio of 0.60 keeps that loss small; Balanced is the sensible default
  for most iPhone clips; Smaller is opt-in.
- Constant quality (`kVTCompressionPropertyKey_Quality`) was considered. It is simpler for the encoder but gives
  unpredictable file sizes, which makes it hard to show an estimate and to test. A target bitrate is predictable.

## Validation plan

- Fixtures: a 4K30 SDR clip, a 4K60 HLG clip, a Dolby Vision profile 8.4 clip, and a 1080p30 clip, each at the three presets.
- Check with the existing quality checks: resolution, fps, color metadata, DV RPU on every frame, metadata atoms
  all unchanged; output bitrate within 15 percent of target; output smaller than the source.
- Add a visual-quality measure on the fixtures (for example VMAF or SSIM against the source) and set minimum scores per
  preset. Adjust the ratios so that Balanced stays above the chosen score on all fixtures.
- Measure encode time and memory on iOS (device) and on Mac, since compression runs at source resolution and is slower than shrink.

## Consequences

- One ratio table and one estimate function. Adding a preset or a future job kind does not touch the queue.
- The ratios may change after fixtures; the ADR will be updated and set to Accepted then.
- Sources with a very low bitrate or already in a small file will often show "already small".

## Alternatives considered

- Fixed bitrates per resolution and frame rate: more tables, worse for odd sources.
- Constant-quality mode: unpredictable size.
- H.264 or other codecs: out of scope. Format change comes later.
