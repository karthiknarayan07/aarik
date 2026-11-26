# Changelog

All notable changes to this project are listed here. Versions follow [Semantic Versioning](https://semver.org).
The release workflow uses the section for a version as its release notes when the tag message adds nothing.

## [0.1.0] - Unreleased

First public release.

### Added

- **Quick runs:** shrink videos without opening the window, from a Dock drop or Open With, a menu bar item (drop videos
  on the icon or its popover, or choose them), the Shrink Videos action and Finder's Services menu. A quick run never
  replaces an original, skips videos that would lose metadata and ends with one notification. The menu bar popover
  lists overlapping runs together, and Settings has rows for the menu bar, notifications, Finder and Services. See
  "Quick runs" in the README.
- **Long batches survive sleep, heat and low battery:** the Mac stays awake while videos convert (the display may
  still sleep). A hot Mac converts one video at a time, then pauses ("Paused while your Mac cools down") and resumes
  by itself. On battery, conversion pauses at 20 % ("Paused: battery low") and resumes when you plug in or it is above
  25 %. A **Conversion Speed** setting (Quiet, Balanced, Fastest) trades speed for heat and noise.
- **Quit asks first while converting:** "Stop converting and quit?" The video in progress and the rest of the queue
  continue the next time you open the app.
- **Shrink Videos action:** in Shortcuts, as a Finder Quick Action, by Siri and in Spotlight. It shrinks the videos you
  give it, or picks them by date range, resolution and source (Local Files or Photos), with the quality, format and
  destination you choose. Nothing is replaced, videos that would lose metadata are skipped, and one notification says
  how it went. Settings explains how to add it to Finder.
- **Replace in Photos:** choose Replace Original in Photos and each smaller copy is saved and checked first. When the
  queue finishes, Photos asks you once to move all the originals to Recently Deleted. If you decline, they are kept
  and a bar offers to move them later. iCloud space is freed when Recently Deleted is emptied, or after 30 days.
- **Overview:** totals for your Photos videos and local files, what converting them could free at the current preset,
  the ten biggest savings (click one to see it in its grid) and the space saved so far.
- **Where to start on Overview:** the biggest groups of videos (by quality, year and library) with Show, which opens
  the right page with filters you can remove. With Apple Intelligence turned on, Smart Picks suggests up to three
  groups, on this Mac only, and Add These to the Queue goes through the usual checks. Nothing is added by itself.
- **Apple Intelligence, on this Mac only:** Ask in Plain Words in the search field, Why? on results that were kept
  as is, have warnings or failed, and Smart Picks on Overview. They use only metadata (formats, sizes, years, reason
  codes) and, for Ask in Plain Words, the words you type, never video content or file names from your library; they work with VoiceOver and the keyboard, and are hidden when Apple
  Intelligence is off or unavailable. Turn it off in System Settings ▸ Apple Intelligence & Siri.
- **A grid that behaves like Finder and Photos:** double-click or Return opens a video (in Photos for Photos videos),
  drag a rectangle over empty space to select several, type a name to jump to it, ⇧-arrows and Home and End extend the
  selection, and the keyboard-focused tile has a ring. The selection turns grey when the window is in the background.
  Drag videos out to Finder or another app (the receiver gets a copy; the original is never moved), and Share them from
  the toolbar or a right-click. Space previews a Photos video's poster frame, and Show in Photos opens it in Photos.
- **Filters, counts and search in the toolbar:** a Filter menu replaces the bar of menus, the window subtitle shows
  how many videos (and how many of them are selected), and the savings summary scrolls with the grid under the toolbar.
  Search says "Search"; the filters Ask in Plain Words makes stay system search tokens.
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
