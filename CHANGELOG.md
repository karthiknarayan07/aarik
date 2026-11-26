# Changelog

All notable changes to this project are listed here. Versions follow [Semantic Versioning](https://semver.org).
The release workflow uses the section for a version as its release notes when the tag message adds nothing.

## [0.1.0] - Unreleased

First public release.

### Added

- **Mac sidebar:** Home (the savings summary), Ask and a Tools section, where Convert is a collapsible group holding Photos, Local Files, Queue, Completed, Kept as Is and Failed. The Go menu follows that order (Home ⌘1, Ask ⌘2) and the window reopens on the page you left.
- **Ask on the Mac:** with Apple Intelligence available, an Ask item in the sidebar (⌘2) holds the on-device assistant, with chat history in the inspector, File → New Chat (⌘N), Return to send, Shift-Return for a new line, Esc to stop, and Ask About This… on videos.
- **iPhone navigation:** the app opens on a Tools list, and each tool owns its interface. Convert has a floating tab
  bar (Overview, Library, Queue and Search) that folds away as you scroll, with Photos and Files inside Library and
  Completed inside Queue; a bar above the tabs shows the video converting now. The Overview leads with a savings ring
  and a headline such as "You've Freed 12.4 GB This Month", pinned cards with small charts, and trends charts that
  VoiceOver can read. Tapping a video opens its page with a zoom. Select works like Photos: tap or swipe across tiles,
  then "Add to Queue" or "Convert Now". Haptics mark selecting, a finished conversion and a pause for battery or heat.
  Previews on long press, swipe actions and sheets with detents follow the system's own apps.
- **iPhone filters, headers, and quality selection:** `4K` / `1080p` quality filters and compact filter submenus
  work across the Photos library, grid headers scroll with content instead of sticking over the title, and tapping
  **Next** on a bulk selection (or opening a video's page) shows a redesigned **Conversion Options** experience with
  a live Before → After size card, plain-English **Resolution** choices (`720p`, `1080p Recommended`, `1440p`,
  `Keep Original`), a **Picture Detail** bit rate slider with tier badges, per-resolution Mbps guides and a "How to
  choose" tip, plus collapsible frame rate and format options.
- **iPhone runs start when you say so:** Add to Queue only queues; Convert Now queues and starts; the Queue has a
  Start button with what the waiting videos would save. Videos handed over by the share sheet or Shortcuts wait in the
  Queue too. A relaunch continues a run you had started, and never starts a queue you hadn't.
- **iPhone Live Activity shows the real stage:** "Downloading from iCloud · 42%", then "Converting · 63%", under
  "Converting 2 Videos", and it stays until the run is over.
- **First launch:** three short screens say your videos stay on the device, ask for Photos access and explain the
  battery and heat rules. They show once and can be skipped.
- **Overview charts:** a savings ring with a one-line insight, summary cards with small charts, and trend charts
  (before and after, savings by group, space saved over time, queue throughput) with VoiceOver summaries. The numbers
  are kept between launches, so the page draws at once and refreshes in the background.
- Colourful symbols in the Mac sidebar; the Mac window keeps its size and layout when you change pages.
- **Photos videos:** a page for the videos in your Photos library, with the same grid, filters, presets and queue as
  Local Files. Browsing never downloads from iCloud; a video is downloaded (with its own progress and a way to cancel)
  only when its turn comes, and the converted copy is saved to Photos as a new video with the original's date,
  location, favorite and albums. The Overview and the README explain the permission and the iCloud timing.
- **Reasons are saved as codes:** each kept-as-is, failed, warning and note result now records a code beside its
  sentence, so Why? explains a result from the code and never from the wording. Results saved by an earlier version
  still open and read as "another detail". Errors from macOS are told by their kind, so the sentences are plain on a Mac
  set to another language.
- **More at home on the Mac:** a working Help menu (README, privacy, release notes, issues); the Dock icon shows a
  progress bar while a video converts and a badge for the videos waiting, and its menu pauses or resumes the queue,
  shows the Queue and adds videos; Edit ▸ Undo Remove from Library; View ▸ Group By and Sort By; a Go menu with
  ⌘1 to ⌘7 for the sections; Pause Queue moved to ⌥⌘P (⌘. is the system's Cancel). Quality presets are a real radio
  group; Add to Queue is a toolbar button instead of a strip in the inspector. Queue, Completed, Kept as Is and Failed
  are selectable lists with a context menu, double-click and Delete; Show in Finder is in the menu, not on every
  row. Status colour is on the symbol only, so text keeps its contrast. The "Queue finished" notification has a Show
  Queue action.
- **Stall protection:** a conversion whose encoder stops responding for a minute now fails with "The encoder stopped
  responding" instead of staying at the same percentage for ever. The partial file is removed and Retry works.
- **Free-space check:** before a conversion writes anything, the app checks that the disk has room for the converted
  video (and, for a Photos video, its download) plus 1 GB to spare. If not, the video fails with "Not enough free space
  on <disk> (needs about X, has Y)", nothing is written, and Retry works once there is room.
- **Quick runs:** shrink videos without opening the window, from a Dock drop or Open With, a menu bar item (drop videos
  on the icon or its popover, or choose them), the Shrink Videos action and Finder's Services menu. A quick run never
  replaces an original, skips videos that would lose metadata and ends with one notification. The menu bar popover
  lists overlapping runs together, and Settings has rows for the menu bar, notifications, Finder and Services. See
  "Quick runs" in the README.
- **Long batches survive sleep, heat and low battery:** the Mac stays awake while videos convert (the display may
  still sleep). A hot Mac converts one video at a time, then pauses ("Paused while your Mac cools down") and resumes
  by itself. On battery, conversion pauses at 20 % ("Paused: battery low") and resumes when you plug in or it is above
  25 %. A **Conversion Speed** setting (Quiet, Balanced, Fastest) sets how many videos convert at once, trading speed for heat and noise.
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
- **Convert:** shrinks 4K iPhone video to 1080p (or 1440p or 720p) in HEVC or H.264, keeping Dolby Vision HDR,
  location, capture date, camera make and model and other metadata. Anything that would be lost is shown before the
  video is queued, and you decide.
- **Local library:** a grid of the videos you add, grouped and sorted, with search, thumbnails and Quick Look. Files on
  drives that are disconnected stay listed and come back when the drive does.
- **Quality filters:** filter the library by resolution and frame rate, file size, length, codec and dynamic range
  (SDR, HDR, Dolby Vision); each option shows how many videos match and how much space they take.
- **Presets with estimates:** choose a preset and see the estimated size and space saved for the selection before
  converting. Advanced options are there when you want them.
- **Queue:** conversions run in the background (several at once on Balanced and Fastest, one on Quiet; iCloud downloads one at a time), can be paused and resumed, and pick up again after the
  app is quit. Activity shows what finished, what was skipped and how much space was saved.
- **Replace:** swap an original for its converted version. The original goes to the Trash, never straight to deletion,
  and can optionally be copied to an originals folder first.
- **Updates:** the app checks for new versions with Sparkle; updates are signed, and automatic checks can be turned
  off in Settings.

### Changed

- **Photos and Files grids scroll smoothly on large libraries:** posters that scroll out of view are no longer fetched, posters decode off the main thread and come back from memory, a library change that touches no video no longer rebuilds the list, and the swipe-to-select gesture no longer sits on the grid while you browse.

- **Convert naming and Mac polish:** the first tool is named **Convert**; controls, menus, alerts and Settings follow
  Title Case and ellipsis conventions across the Mac app; disabled "Soon" placeholder rows and the single-item Tools
  sidebar section are removed; pressing Delete on a running conversion in the Queue asks first; the menu bar popover
  shows every running conversion; and clicking or dragging a section header no longer clears the grid selection.
