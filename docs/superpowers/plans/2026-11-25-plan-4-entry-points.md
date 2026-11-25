# Plan 4 — Quick Runs: Dock, Menu Bar, Finder, Shortcuts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Videos can be sent to the app without opening its window. The entry points are:

- dropping on the Dock icon
- dropping on the menu bar icon
- Finder right-click (a Shortcuts Quick Action plus a Services item)
- a Shortcuts action

All quick runs convert in the background with the saved defaults, skip any file that would lose metadata, and post one notification that lists what was converted and what was skipped. Clicking the notification opens the app with the skipped files ready to review (§8.5a).

**Architecture:**

- **One shared model.** `AppModel` becomes a process-wide `@MainActor` singleton, `AppModel.shared`, created in `AppDelegate` before any scene. Window, menu bar, App Intents, Services and Dock drops all feed the one `JobQueue`.
- **`QuickRun` service in the app target.** It takes URLs (plus optional overrides), plans them with the saved defaults and the loss check, enqueues the convertible ones, records skipped files under a run ID in a small `QuickRunStore`, and posts the completion notification when that run's jobs finish.
- **Intents live in the main app target.** App Intents run in the app process, which avoids extension inter-process communication.
- **Menu bar.** `MenuBarExtra(.window)` provides the popover with queue progress. Drops onto the status icon itself need an AppKit `NSStatusItem` overlay view that registers for file URLs.

**Tech stack:**

- AppIntents (`AppIntent`, `AppShortcutsProvider`, `IntentFile`, `supportedModes = .background`)
- `NSServices` in Info.plist
- SwiftUI `MenuBarExtra`, plus an AppKit `NSStatusItem` drop overlay
- `CFBundleDocumentTypes` and `application(_:open:)`
- UserNotifications with a category action

**Spec:** §8.1 (inputs), §8.5a (quick runs), §8.6 (notifications), §9 (menu bar), §12 (Finder/Shortcuts may slip if unsigned builds make them unreliable).

**Research:** `docs/research/plan-4-entry-points.md`. Its "[exp]" claims are unverified; Task 1 verifies them.

## Global Constraints

- All Plan 2 and Plan 3 constraints still hold:
  - brand-neutral code
  - macOS 26, arm64
  - Swift 6 strict concurrency, zero warnings, lint clean
  - no third-party dependencies (hand-roll the status item overlay; do not add MenuBarExtraAccess)
  - offline
- **Quick runs never ask questions, never open the window and never Replace.** They use the Save to setting. When that setting is Replace, a quick run saves next to the original instead and says so in the notification. Replace always needs the window's confirmation.
- **Loss policy: skip.** Any file whose predicted report has a "lost" entry is not queued. Files that land in Kept As Is (already small, under 10 %, spatial) are counted as skipped with their reason.
- There is one queue, so two quick runs never encode in parallel.
- No notification is posted while the app is frontmost (§8.6).
- If Finder Quick Action or Shortcuts proves unreliable on an ad-hoc build after Task 1, that entry point is shipped disabled behind a note in Settings. It must not block the release (§12).

## Review Focus

1. **Cold start from Finder or Shortcuts** (app not running): the intent runs, the app stays windowless, the job runs, the notification arrives and output files are returned.
2. **Two quick runs in quick succession, plus window adds:** one queue, no duplicate jobs (the existing SourceKey dedupe), each run's notification lists only its own files.
3. **Dock drop during cold launch:** the URLs are buffered until the model exists and delivered exactly once (no double delivery via `onOpenURL`).
4. **Quick run with Replace as the saved destination:** never replaces; saves next to the original; the notification says why.
5. **Clicking the notification after the app quit:** the app relaunches, the delegate receives the response, and the skipped files appear for review.

---

### Task 1: Entry-point spike on an ad-hoc build in /Applications

Use a throwaway branch and work through the checklist at the end of `docs/research/plan-4-entry-points.md`. For each item, verify:

- Shortcuts lists the intent.
- "Use as Quick Action › Finder" appears and runs with the app quit.
- The Services item appears.
- The status item accepts a drop.
- A Dock drop at cold launch arrives.
- The notification action fires after a relaunch.

Record the outcomes in `docs/adr/0003-quick-run-entry-points.md` and amend Tasks 3–6 accordingly.

### Task 2: Shared model and the `QuickRun` service

**Shared model:** `AppModel.shared`, created in `AppDelegate.init`. Window scenes read it.

**`QuickRun.run(urls: [URL], overrides: QuickRunOverrides?) async -> QuickRunReceipt`.** The receipt holds:

- `runID`
- `queuedJobIDs`
- `skipped: [(URL, reason)]`

**`QuickRunStore`:** persisted JSON of runs, holding `runID`, job IDs and skipped entries. Runs older than 7 days are pruned at launch.

**Notification:**

- Posted once every job of a run reaches a terminal state.
- Body example: "3 converted, saved 1.2 GB. 2 skipped."
- Category `QUICK_RUN_DONE`, with the action "Review skipped files".
- Uses the existing `QueueNotifier` frontmost rule.

**Tests** (fake queue/clock where needed):

- loss → skipped
- kept-as-is → skipped with its reason
- Replace setting → next-to-original, with a note
- receipt bookkeeping
- notification fires once per run

### Task 3: Dock drop and Open With

- Info.plist `CFBundleDocumentTypes`:
  - role Viewer
  - `LSHandlerRank` Alternate
  - UTIs `com.apple.quicktime-movie`, `public.mpeg-4`, `com.apple.m4v-video`
- `AppDelegate.application(_:open:)`:
  - Buffers URLs until launch finishes.
  - If the window is open, the files are added to Local Files and nothing is queued (window behaviour).
  - If no window is visible, they go through `QuickRun`.
  - This rule is documented in the README.

### Task 4: Menu bar

- `MenuBarExtra` with `.window` style:
  - The label is an SF Symbol that turns into a progress symbol while the queue runs.
  - The popover shows the current job with its progress, the queue count, Pause/Resume, "Open main window", and a drop zone that calls `QuickRun`.
- `StatusItemDropOverlay`, an AppKit view placed over the status item button:
  - It registers for `.fileURL`, accepts movies only and forwards them to `QuickRun`.
  - Clicks pass through to the button.
  - If attaching to the `MenuBarExtra`'s own status item proves impossible, use our own `NSStatusItem` instead of `MenuBarExtra`, with an `NSPopover` hosting the same SwiftUI view.
- Setting "Show in menu bar" (default on).

### Task 5: Shortcuts action (and Finder Quick Action through it)

`ShrinkVideosIntent`:

- **Parameter `files: [IntentFile]`:** movie types only.
- **Optional parameters:**
  - `quality`, an AppEnum of High, Balanced and Smaller
  - `format`, an AppEnum of HEVC and H.264
  - `destination`, an AppEnum of Next to original and Folder, with a `folder: IntentFile?` when Folder is chosen
  - `waitForCompletion: Bool`, default true
- **Behaviour:**
  - `supportedModes = .background`
  - runs `QuickRun`
  - when waiting, awaits the run's jobs and returns `[IntentFile]` outputs
  - otherwise returns immediately with an empty list and a dialog naming the count queued
- **`AppShortcutsProvider`:** one phrase, "Shrink videos with ${applicationName}".
- **Settings:** an "Add to Finder" help row explaining "Shortcuts › the action › Use as Quick Action › Finder", with a button that opens Shortcuts.
- **Tests:** intent parameter mapping to `QuickRunOverrides`.

### Task 6: Services menu item

- Info.plist `NSServices` entry:
  - "Shrink Videos"
  - send types `public.file-url`
  - `NSRequiredContext` for movies
- `NSApp.servicesProvider` with `shrinkVideos(_:userData:error:)` reading file URLs from the pasteboard and calling `QuickRun`.
- Run `NSUpdateDynamicServices()` at launch.

### Task 7: Polish and docs

- VoiceOver labels on the menu bar popover.
- README section "Quick runs", including the Finder setup steps and the unsigned-build caveats.
- Settings rows for the menu bar, notifications and the Finder help.
- The full test suite and lint pass.
- Manually test every Review Focus item on an ad-hoc build in /Applications.
