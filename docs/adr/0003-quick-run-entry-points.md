# ADR 0003: Quick-run entry points on an ad-hoc build

Status: **DRAFT — spike built, every outcome pending manual check**

## Context

Plan 4 Task 1 (`docs/superpowers/plans/2026-11-25-plan-4-entry-points.md`) asks which quick-run entry points work
on an ad-hoc-signed build installed in /Applications. The research (`docs/research/plan-4-entry-points.md`) marks
most of its claims "[exp]", meaning unverified. This spike wires each entry point minimally on the throwaway branch
`spike/plan-4-entry-points` (cut from `plan-2-app-shell`) so a person can check it by hand. The checklist at the end
of the research doc is the list below.

The spike code is not Plan 4 code. In particular:

- `AppModel.quickRun(_:origin:)` uses the saved preset and the saved Save to default, never Replace.
- It skips the loss check: the spike quick run converts lossy files instead of skipping them.
- It enqueues into the one shared `JobQueue` and polls the mirrored job list until its jobs finish.
- It posts the notification even while the app is frontmost.

## Build and environment

- Built with Xcode 27.2 (27B52), SDK MacOSX27.2, deployment target macOS 26.0, arm64, ad-hoc signature with
  hardened runtime (`flags=0x10002(adhoc,runtime)`). The build had zero errors and zero warnings.
- The machine the spike was built on runs macOS 27.2.1 (26B131). Results checked on it say nothing yet about
  macOS 26.x.
- Built app: `.build/spike/Build/Products/Release/aarik.app` in the worktree. Bundle id
  `io.github.karthiknarayan07.app`.
- `Metadata.appintents` is present in the bundle. Its `extract.actionsdata` lists `ShrinkVideosIntent` with
  `supportedModes = 1` (background) and `openAppWhenRun = false`, plus the auto shortcut "Shrink videos with
  ${applicationName}".

## How to read the result

Every entry point writes one line per event, in two places:

- the unified log, subsystem `io.github.karthiknarayan07.app`, category `spike`, level notice
- `~/Library/Logs/io.github.karthiknarayan07.app-spike.log`, with a timestamp and pid prefix

To watch the file:

```sh
tail -f ~/Library/Logs/io.github.karthiknarayan07.app-spike.log
```

To watch the unified log:

```sh
log stream --predicate 'subsystem == "io.github.karthiknarayan07.app" AND category == "spike"'
```

Every launch logs `SPIKE launch willFinish path=…` and then `SPIKE launch didFinish …`. Use the `path=` value to
confirm that the /Applications copy ran, not the DerivedData copy. A different `pid=` on a line shows that the
event cold-launched the app.

### Common setup (once, before the checks)

1. Quit any running copy of the app.
2. Copy the built app to /Applications, replacing any older copy.
3. Remove the build copy from LaunchServices so routing doesn't go to DerivedData:
   `lsregister -u <worktree>/.build/spike/Build/Products/Release/aarik.app`.
   The tool is at `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`.
4. Register the installed copy: `lsregister -f /Applications/aarik.app`.
5. Open the app once from /Applications. If Gatekeeper blocks it, allow it in System Settings › Privacy & Security.
   Then quit it.
6. Keep a small test set ready: three short `.mov` files (iPhone clips are best) and one non-video file. Outputs go
   next to the originals unless the saved Save to default is a folder.

Spike switches, set with `defaults write io.github.karthiknarayan07.app <key> …` while the app is quit:

| Key | Values | Effect |
|---|---|---|
| `spike.ownStatusItem` | `-bool NO` (default) / `-bool YES` | NO: SwiftUI `MenuBarExtra(.window)` and an overlay found by scanning its window. YES: our own `NSStatusItem` + `NSPopover` hosting the same SwiftUI panel. |
| `spike.overlayHitTest` | `events` (default) / `never` / `always` | How the overlay lets clicks through (see item 3). |

## 1. Shortcuts action and Finder Quick Action (App Intent)

**Wired:**

- `Apps/macOS/Sources/ShrinkVideosIntent.swift`: `ShrinkVideosIntent` lives in the app target. It sets
  `static let supportedModes: IntentModes = .background` and has the parameter
  `@Parameter(title: "Videos", supportedContentTypes: [.movie]) var files: [IntentFile]`.
- `perform()` is `@MainActor`. It uses each file's `fileURL` (with `startAccessingSecurityScopedResource`), or
  stages data-only files into Application Support/<bundle id>/Staging. It then calls
  `AppModel.shared.quickRun(urls, origin: "intent")`, waits for the jobs to finish, and returns
  `ReturnsValue<[IntentFile]>` built from the output URLs.
- `QuickRunShortcuts: AppShortcutsProvider` has the phrase "Shrink videos with ${applicationName}", short title
  "Shrink Videos" and symbol `film.stack`.
- `AppModel.shared` is a new `static let` that `AppDelegate` uses as its model. An intent that runs first creates
  the same instance.

**Manual steps:**

1. Open Shortcuts.app. Search the action library for "Shrink Videos" and note whether the app's section lists it,
   and whether the App Shortcut tile appears without making a shortcut.
2. Make a shortcut with Receive input (Files, Movies) from Quick Actions › Shrink Videos › Show in Finder (or Quick
   Look). In the details pane, turn on "Use as Quick Action" and choose Finder.
3. Quit the app. In Finder, right-click one `.mov` › Quick Actions › your shortcut.
4. Repeat with three `.mov` files selected.
5. Repeat with the app already running.
6. Also run the shortcut from Shortcuts.app with a file picked, to see whether Shortcuts gives a file URL or only
   data.

**Log lines that prove it:**

- `SPIKE intent perform files=N withURL=M coldLaunch=… visibleWindows=… active=…`
  - `files=3` for the three-file run.
  - `withURL=` shows whether Finder and Shortcuts hand over file URLs.
  - `visibleWindows` and `active` show whether the background mode kept the window and activation away.
- `SPIKE quickRun origin=intent movies=N queued=N …`, then `SPIKE quickRun done origin=intent converted=… skipped=…`
- `SPIKE intent return outputs=N`, and then Show in Finder reveals the output files.

Also note whether a main window appeared on a cold launch. A SwiftUI `WindowGroup` may open one even in background
mode, and that alone decides how Plan 4 handles cold starts. Also note any Shortcuts timeout on long jobs.

**Learned from the SDK:**

- `supportedModes` is `@available(anyAppleOS 26.0, *)`.
- `openAppWhenRun` is deprecated on macOS 26.0 ("Please provide 'supportedModes' instead"), so no fallback was
  needed.
- `IntentModes` offers `.background`, `.foreground` and `.foreground(_:)`, with `ForegroundMode` values
  `.immediate`, `.dynamic` and `.deferred`.
- `IntentSystemContext.currentMode` reports the mode at run time.
- The macOS 27 SDK adds `allowedExecutionTargets` (`anyAppleOS 27.0`); the spike does not use it.
- `IntentFile` has `fileURL: URL?`, `data`, `filename`, `type` and `removedOnCompletion`.
- A `@MainActor` `perform()` and a `static let supportedModes` compile clean under Swift 6 complete concurrency.
- The App Intents metadata processor runs for every package target too, and logs "Extracted no relevant App Intents
  symbols" for them. Only the app target writes `Metadata.appintents`.

Outcome: pending manual check

## 2. Services menu ("Shrink Videos")

**Wired:**

- `Apps/macOS/Info.plist` has an `NSServices` entry:
  - `NSMenuItem.default` = "Shrink Videos"
  - `NSMessage` = `shrinkVideos`
  - `NSPortName` = `$(PRODUCT_NAME)`, which expands to `aarik`
  - `NSSendFileTypes` = `[public.movie]`
  - `NSRequiredContext` = `{}`
- `Apps/macOS/Sources/ServiceProvider.swift` implements
  `@objc func shrinkVideos(_:userData:error:)`. It reads `NSURL`s with `.urlReadingFileURLsOnly` and calls
  `quickRun(origin: "service")`.
- `applicationDidFinishLaunching` sets `NSApp.servicesProvider` and calls `NSUpdateDynamicServices()`.

**This differs from the plan's wording.** Plan Task 6 says "send types `public.file-url`, `NSRequiredContext` for
movies". `NSRequiredContext` has no file-type key; its keys are `NSApplicationIdentifier`, `NSTextLanguage`,
`NSWordLimit`, `NSTextScript` and `NSTextContent`. `NSSendTypes public.file-url` would offer the item for any file.
The documented way to filter a Finder service by file type is `NSSendFileTypes`, so the spike uses that. The empty
`NSRequiredContext` is there so the service is enabled without a trip to Keyboard Shortcuts settings. Whether that
holds on macOS 26/27 is part of this check.

**Manual steps:**

1. With the app installed and launched once, run `/System/Library/CoreServices/pbs -flush` (or log out and in).
2. In Finder, right-click one `.mov` and check the menu bottom and Services ›. Note whether "Shrink Videos" is there,
   and whether it is top-level or in the submenu.
3. Right-click a non-video file. The item should not appear.
4. If it is missing, check System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders. Note
   whether it is listed and whether it is enabled.
5. Run it with the app quit, then with the app running, then on three files.

**Log lines that prove it:**

- `SPIKE service files=N coldLaunch=… types=…`
  - `types=` shows which pasteboard types Finder sent.
  - A new `pid=` together with `SPIKE launch …` lines just before shows a cold launch.
- `SPIKE quickRun origin=service …`, then `SPIKE quickRun done origin=service …`

Outcome: pending manual check

## 3. Menu bar status item: drop on the icon, click still opens the panel

**Wired:**

- `Apps/macOS/Sources/MainApp.swift`: `MenuBarExtra(isInserted:)` with `.menuBarExtraStyle(.window)`.
  - It is inserted unless `spike.ownStatusItem` is YES.
  - The label is `film.stack` plus the pending count.
  - The panel (`MenuBarPanel`) shows the app name, "N in queue", the running file with a progress bar,
    Pause/Resume, "Open main window", and a SwiftUI `.dropDestination(for: URL.self)`.
- `Apps/macOS/Sources/MenuBarSpike.swift`:
  - `StatusItemDropController` finds the `MenuBarExtra`'s button. SwiftUI exposes no `NSStatusItem`, so it scans
    `NSApp.windows` for `NSStatusBarWindow` instances and walks their content view to an `NSStatusBarButton`. It
    retries every 0.5 s, up to 20 times.
  - It then adds a `StatusItemDropOverlay` (an `NSView` with `registerForDraggedTypes([.fileURL])`) that accepts
    movies only.
  - In own-item mode it makes an `NSStatusItem` + `NSPopover` hosting the same `MenuBarPanel`, with the same
    overlay.
- Overlay click pass-through, set by `spike.overlayHitTest`:
  - `events` (default): `hitTest` returns nil for mouse button events and itself otherwise.
  - `never`: always nil. This works only if AppKit's drag-destination lookup ignores `hitTest`.
  - `always`: the overlay takes the click and forwards it with `button.performClick(nil)`.

**Manual steps:**

1. Launch the app and check the log for `SPIKE statusOverlay attached=true via=menuBarExtraWindowScan(buttons=1)`.
   If it says `attached=false`, the line lists the window classes it saw.
2. Check that the icon is visible. macOS 26+ may hide it behind System Settings › Menu Bar › "Allow in the Menu
   Bar".
3. Click the icon. The panel should open, and `SPIKE menuBarPanel appeared` should be logged the first time. Click
   again to close it.
4. Drag one `.mov` from Finder onto the icon. Watch whether the icon accepts it (copy cursor) and then the log.
5. Drag a non-video file onto the icon. It should be rejected.
6. Open the panel and drop a `.mov` inside it.
7. Repeat steps 3–5 with `spike.overlayHitTest` set to `never`, then to `always`.
8. Repeat with `spike.ownStatusItem` YES.

**Log lines that prove it:**

- `SPIKE statusDrag entered movies=N mode=…` (the drag reached the overlay)
- `SPIKE statusDrop files=N mode=…`
- `SPIKE quickRun origin=statusDrop …`
- `SPIKE panelDrop files=N` (drop inside the panel)
- Clicks:
  - `SPIKE menuBarPanel appeared` (MenuBarExtra mode, first open)
  - `SPIKE statusClick ownStatusItem popoverShown=…` (own-item mode)
  - `SPIKE statusClick forwarded mode=…` (the overlay caught a click and forwarded it)

Record, for each hit-test mode: whether clicks open the panel, whether drops arrive, and whether a "forwarded" line
appears.

**Learned from the SDK:**

- `MenuBarExtra` still has no public way to reach its `NSStatusItem` in the macOS 27.2 SDK.
- The window scan depends on the private class name `NSStatusBarWindow`, so Plan 4 should only rely on it if this
  check passes. Otherwise own-item mode is the plan's documented fallback.

Outcome: pending manual check

## 4. Dock drop and Open With (cold launch and running)

**Wired:**

- `Apps/macOS/Info.plist` has `CFBundleDocumentTypes`: one entry "Video", role Viewer, `LSHandlerRank` Alternate, UTIs
  `com.apple.quicktime-movie`, `public.mpeg-4` and `com.apple.m4v-video`.
- `AppDelegate.application(_:open:)` logs every call.
  - Before `applicationDidFinishLaunching` it buffers the URLs; that method delivers them.
  - Delivery calls `model.addFiles` (Local Files).
  - The same URL delivered again within 5 s is dropped and logged as a duplicate.
  - One second after delivery it logs the visible window count, to show whether SwiftUI opened an extra window.
- No `onOpenURL` anywhere, so there is no second delivery path.
- The `WindowGroup` now has the id `main`, used by `openWindow`.

**Manual steps:**

1. Quit the app and keep its Dock icon (Options › Keep in Dock). Drag one `.mov` onto the Dock icon.
2. With the app running, drag two `.mov` files onto the Dock icon.
3. Right-click a `.mov` › Open With. Check that the app is listed (Alternate rank) and that QuickTime is still the
   default.
4. Run `open -a /Applications/aarik.app file.mov` with the app quit, then again with it running.
5. Drag a non-video file onto the Dock icon. The icon should not highlight.

**Log lines that prove it:**

- `SPIKE open urls=N coldLaunch=true visibleWindows=…`, then `SPIKE open delivered urls=N coldLaunch=true
  to=localFiles`. Check that `SPIKE launch didFinish … pendingOpen=N` comes in between.
- While running: `SPIKE open urls=N coldLaunch=false …`, then `SPIKE open delivered … coldLaunch=false`.
- `SPIKE open windowsAfter visible=N`: more than one main window means SwiftUI opened an extra window per event.
- No `SPIKE open duplicate …` lines. If any appear, the same event was delivered twice.

Outcome: pending manual check

## 5. Notification with an action, including after the app quit

**Wired:**

- `Apps/macOS/Sources/QuickRunNotifications.swift`:
  - `install()` runs in `applicationWillFinishLaunching`. It sets the `UNUserNotificationCenter` delegate and
    registers category `QUICK_RUN_DONE` with action `REVIEW_SKIPPED`, "Review skipped files" (`.foreground`).
  - Authorization is requested on the first quick run, and the result is logged.
  - When a quick run's jobs finish, it posts "Quick run finished: N converted, saved X. M skipped." with that
    category.
  - `willPresent` returns banner, list and sound, so it shows even while the app is in front.
  - `didReceive` logs the action and brings the main window forward. It uses an existing window, or SwiftUI
    `openWindow(id: "main")` captured from the menu bar label or the window.
- The existing "Queue finished" notification from `QueueNotifier` still posts, but only when another app is in
  front and without a category.

**Manual steps:**

1. Start a quick run from any entry point (Services or a status drop are quickest). Allow notifications when asked.
2. When the run finishes, a banner should appear. Use the action menu's "Review skipped files", and in another run
   click the banner body.
3. Quit the app before the notification is clicked: start a run, wait for the banner, quit with ⌘Q, and then click
   the banner or its action in Notification Center.
4. Check System Settings › Notifications for the app's entry. Copy a rebuilt (re-signed) app over the old one and
   check whether macOS asks for permission again.

**Log lines that prove it:**

- `SPIKE notification delegate installed` (every launch)
- `SPIKE notification requestAuthorization granted=true|false`
- `SPIKE notification posted origin=… auth=N alertStyle=N`. `auth` 2 is authorized and 1 is denied. `alertStyle` 1
  is banner, 2 is alert and 0 is none. `SPIKE notification post failed …` means posting itself was refused.
- `SPIKE notification willPresent …` (only when the app was in front)
- `SPIKE notification didReceive action=REVIEW_SKIPPED|com.apple.UNNotificationDefaultActionIdentifier
  category=QUICK_RUN_DONE coldLaunch=…`. After a quit, expect a new `pid=` and `coldLaunch=true`, or a `false`
  logged just after launch finished. The order relative to `SPIKE launch didFinish` is the point of the check.
- `SPIKE openMainWindow reason=notification via=existingWindow|openWindow|none`

**Learned from the SDK:**

- The delegate is a `@MainActor` class whose `UNUserNotificationCenterDelegate` methods are the async variants,
  marked `nonisolated`. Each pulls out the `String`s it needs and hops to the main actor. This compiles without
  warnings under Swift 6.
- `applicationDidFinishLaunching` also logs whether the launch was a default launch and the `userInfo` keys. That
  shows whether a notification relaunch is visible to AppKit.

Outcome: pending manual check

## Decision

To be written after the manual checks. For each entry point: keep it as wired, change it (for example, the own
`NSStatusItem` instead of the `MenuBarExtra` window scan), or ship it disabled behind a Settings note (§12). Then
amend Plan 4 Tasks 3–6.

## Manual results (2026-11-25, macOS 27.2.1, /Applications copy)

- **Release signing (blocker found, fixed on plan-2-app-shell in 1678d5b by `ENABLE_HARDENED_RUNTIME = NO`):** the Xcode Release build (ad-hoc + hardened runtime) crashes at launch: dyld
  refuses the embedded Sparkle.framework ("different Team IDs"; library validation). Re-signing the way
  `scripts/make-dmg.sh` does (`codesign --force --deep -s -`, which drops the runtime flag) launches fine. Ruling to
  make: set `ENABLE_HARDENED_RUNTIME = NO` for ad-hoc builds (it can't be notarized anyway) so the raw build and
  the DMG behave the same.
- **Item 4, Dock drop / Open With: works.** Cold launch: `open urls=1 coldLaunch=true` → delivered once to Local
  files. While running: delivered once, BUT SwiftUI's WindowGroup opened a SECOND main window. Plan 4 must use a
  single `Window` scene or `.handlesExternalEvents(matching: [])`.
- **Item 3, status item drop: works** with MenuBarExtra + overlay (found via the NSStatusBarWindow scan, a private
  class name; fragile). Drop → `statusDrop files=1` → quickRun → notification posted (auth granted, banner). A click
  still opens the panel.
- **Item 2, Services: registered, off by default.** `pbs -dump_pboard` lists "Shrink Videos" (public.movie, bundle
  path /Applications/aarik.app), but neither Finder's right-click nor Finder ▸ Services shows it: the user has to
  switch it on in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services. Decision for Plan 4: keep the
  Services entry, add a Settings help row that explains and opens that pane; the Shortcuts Quick Action is the
  primary Finder path.
- **Items 1 and 5 (Shortcuts, notification click after quit): not checked yet.**
