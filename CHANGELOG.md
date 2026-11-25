# Changelog

All notable changes to this project are listed here. Versions follow [Semantic Versioning](https://semver.org).
The release workflow uses the section for a version as its release notes when the tag message adds nothing.

## [0.1.0] - Unreleased

First public release.

### Added

- **Shrink Videos action:** in Shortcuts, as a Finder Quick Action, by Siri and in Spotlight. It shrinks the videos you
  give it, or picks them by date range, resolution and source (Local Files or Photos), with the quality, format and
  destination you choose. Nothing is replaced, videos that would lose metadata are skipped, and one notification says
  how it went. Settings explains how to add it to Finder.
- **Safe updates:** an update that finishes installing waits to relaunch the app until the queue has no running or
  waiting jobs (a paused queue doesn't hold it).

- **Downscale Video:** shrinks 4K iPhone video to 1080p (or 1440p or 720p) in HEVC or H.264, keeping Dolby Vision HDR,
  location, capture date, camera make and model and other metadata. Anything that would be lost is shown before the
  video is queued, and you decide.
- **Local library:** a grid of the videos you add, grouped and sorted, with search, thumbnails and Quick Look. Files on
  drives that are disconnected stay listed and come back when the drive does.
- **Quality filters:** filter the library by resolution and frame rate, file size, length, codec and dynamic range
  (SDR, HDR, Dolby Vision); each option shows how many videos match and how much space they take.
- **Presets with estimates:** choose a preset and see the estimated size and space saved for the selection before
  converting. Advanced options are there when you want them.
- **Queue:** conversions run one at a time in the background, can be paused and resumed, and pick up again after the
  app is quit. Activity shows what finished, what was skipped and how much space was saved.
- **Replace:** swap an original for its converted version. The original goes to the Trash, never straight to deletion,
  and can optionally be copied to an originals folder first.
- **Updates:** the app checks for new versions with Sparkle; updates are signed, and automatic checks can be turned
  off in Settings.
