# Competitor notes (2026-11-25)

Paraphrased research used for the Plan 2/3 UI direction. Inspiration only: we take layout and interaction ideas, never names, icons, copy or visual styling.

## KeepFeather (keepfeather.com) — closest match
Mac app that shrinks videos and photos in the Photos library and replaces originals with smaller copies. One-time Pro purchase, free tier limited; Apple silicon, macOS 14+.

- **Flow:** metadata-only library scan (no iCloud download) → Photos-like grid (group by year/month, sort biggest/newest, media-type filters, albums) → pick quality (video High keeps 4K; lower levels give 1080p HEVC; photo levels as HEIC) with an estimated copy size per item, optional sample-based "exact" estimate → optional side-by-side compare → serial queue (pause, quiet/thermal mode) → results in Completed / Kept As Is (with reason, minimum saving) / Failed (reason, retry).
- **Originals:** copy is verified (duration, resolution, date, location, camera, HDR, Dolby Vision per-frame data) before import; originals optionally saved to a folder; originals reach Recently Deleted only on an explicit user action; UI explains iCloud space frees after 30 days / emptying.
- **UI patterns:** sidebar (Library, Media Types, Activity, Insights, Albums) · grid with size + HDR/RAW/Edited badges · right inspector with per-quality estimates and % saved · "Could free about X GB" header with a quality slider · Overview dashboard by category with "Show" / "Add All to Queue" · short reassurance lines on first run.
- **Hard problems from its changelog:** Dolby Vision brightness, time zones, rotation/frame timing, Action Mode clips, copies already deleted being miscounted, two app instances clashing, repeated permission prompts. User requests: hide finished items, choose working folder, auto-start queue, simpler settings.

## Swivel (github.com/jonathanlotan/Swivel) — MIT
Free offline converter driven by a drag-and-drop radial menu (convert / tools / actions). Swift + SwiftUI/AppKit, Apple frameworks only, Finder Quick Action, Shortcuts, Services. Architecture mirrors ours: UI-free core package + CLI, thin app/extension shells, and a test that fails if networking APIs are linked (offline guarantee). Not Photos-aware; no Dolby Vision handling stated.

## Others (brief)
- **HandBrake:** Dolby Vision passthrough on 10-bit VideoToolbox HEVC; powerful but heavy settings; not Photos-aware.
- **Permute:** simple drag-and-drop, hardware accelerated; little control; no DV claims.
- **iOS compressors (Bonsai, TinyVid, Compressy, Gallery Optimizer):** common gap is unclear replace semantics and no metadata/HDR guarantees.

## Takeaways adopted (see spec §8.2, §8.5, §9, §10a)
Savings estimates before converting · library-first grid + inspector · presets High/Balanced/Smaller · Kept As Is with reasons · serial persistent queue with pause · verify-then-replace with optional originals backup · plain trust copy · offline guarantee test.
