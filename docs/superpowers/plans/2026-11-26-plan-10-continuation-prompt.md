# Continuation prompt: Aarik real-device fixes and the test-hardening pass (paste into a new agent)

You are continuing work on Aarik. Your working directory is `/Users/karthiknarayan/Developer/personal/aarik`, on the integration branch `plan-2-app-shell`, which tracks `origin/plan-2-app-shell`. HEAD is the commit that added this prompt, on top of `7e14de7` and `be04853`.

## Read first
- `AGENTS.md`.
- `docs/testing/performance-and-device.md`: how to test on the device and how to measure scrolling.
- `docs/RELEASING.md`: the real-device checklist.
- `docs/adr/0006-tool-core-services-and-scenes.md`: the architecture. It was amended for the Mac shell sidebar.
- The ledger `.superpowers/sdd/2026-11-26-plan-10-ios-and-convert/progress.md`.

## Owner rules (non-negotiable)
1. **Never take over the owner's screen.** Don't run Mac XCUITests, launch the app, or drive the UI while the owner is using the Mac. Ask first, and run any UI test at most twice: once to reproduce, once to confirm. Diagnose from the code and the logs. iPhone device UI tests take over the phone, so ask before those too.
2. **Converted media goes back to its original place in Photos.** The new asset keeps:
   - the creation date, location and camera metadata
   - **every user album the original was in**
   - favourite and hidden
   - the caption where possible

   PhotoKit can't set `dateAdded`, so with the "Added" sort the copy shows at the end, and "Saved from Aarik" is added by iOS. Editing in place keeps the original as well and saves no space, so it is rejected. With the **Captured** sort the copy must sit exactly where the original was.
3. **Battery:** a low battery only shows a warning and never blocks or pauses a run. Heat protection stays (Serious slows the run, Critical pauses it).
4. **Running:** at most 3 parallel subagents. Product code comes first, tests after. Push `plan-2-app-shell` after every merge. Never touch `main`. Stop at about 70–80% of the usage window and refresh this prompt.
5. **Code and copy:**
   - Code stays brand-neutral.
   - App-level screens (onboarding, Home, Browse, the Mac shell) never name a tool. `scripts/text-lint.py` enforces this, with an allowlist.
   - User-facing strings use "…", never "...".
6. **Look:** native first, in the style of Apple Health and Fitness: colourful SF Symbols and Swift Charts, with SwiftData caching the stats. Never copy another app.
7. **Verify in the real app.** After any UI merge, check the real running app, once the owner OKs screen use. Never sign off on ImageRenderer shots or fakes alone.

## Done today (merged and pushed to `plan-2-app-shell`)
- **Mac real-app fixes:**
  - Overview data loads (the `.task` lifecycle was moved onto a `ZStack`).
  - Ask search ignores generic words, so "biggest videos" no longer looks for that file name.
- **iPhone launch crash fixed (1f50cbb).** The `BGTaskScheduler` launch handler was inferred `@MainActor` and trapped on the queue iOS calls it on. It is now `@Sendable`. Onboarding copy is tool-neutral.
- **Mac sidebar.**
  - The shell owns Home and Ask, then a Tools section, with Convert as a collapsible group of its own pages.
  - The Go menu runs ⌘1 Home, ⌘2 Ask, then the Convert pages.
  - `MacShellPage` and `homeSummary()` are the new scene hooks.
- **Mac Home polish:**
  - The stat cards sit 4 across or 2×2, never 3 + 1.
  - Chart labels sit above the bars.
  - Convert's toolbar items show only on Convert pages.
  - Charts with one data point show "Not enough history yet".
- **The Mac window no longer resizes on page switch (be04853).** Inspector visibility is now the window's choice, not the page's. Home shows the tool's no-selection inspector. Fixed from the code; **the owner has not confirmed it by eye yet.**
- **iPhone explicit start:**
  - The Select bar offers Add to Queue and Convert Now. Queue has a Start button.
  - `autoStartQueue` is off by default on iOS.
  - On relaunch, only an interrupted run resumes.
  - Share-sheet and intent hand-offs queue the video and open Queue.
  - The Live Activity reads "Converting N Videos", with "Downloading from iCloud · NN%" and then "Converting · NN%". It asks for a new activity if the system ends one.
- **Photos grid scroll fix (shared by Mac and iPhone):**
  - The swipe-to-select gesture is active only in Select mode; before, it blocked scrolling.
  - Thumbnail requests are cancelled when a tile leaves the screen.
  - Library diffs run off the main thread, coalesced to about 4 per second.
  - There is one caching image manager.
  - The real iPhone 14 Pro Max shows 0 hitches at about 90 fps.
  - `scripts/device-perf.sh` and `scripts/verify.sh --perf` were added, and the docs are in `docs/testing/performance-and-device.md`.
- **Ask quality:**
  - The model gets today's date and understands relative years.
  - Search output leads with totals.
  - New `savings_so_far` and `allow_photos_access` tools (the access tool goes through a confirm card).
  - A tool call written as text is hidden and retried once.
  - The eval scored 45, 43 and 44 out of 45.
- **Package test hardening:**
  - Fakes now behave like iOS: a background-queue BG handler, iCloud-only assets, and every Photos authorization state.
  - The owner's rules are written as tests.
  - The `text` verify group catches ellipses and tool names.
  - The real-AI eval is `RealAssistantEverydayPhrasingTests` (run with `RUN_REAL_AI=1`).
- **Installed builds (7e14de7):** the Mac Release is in `/Applications/Aarik.app`. The iPhone has a Release build signed with Personal Team `95J795334T` and `CODE_SIGN_ENTITLEMENTS=""`, because a Personal Team has no App Group: the share extension and widget data don't work.

## Unfinished: WIP branches pushed to origin, not merged, untested
Each branch is one `wip:` commit on top of `plan-2-app-shell`. Review, finish and test each one, then merge it.
1. **`plan-10/battery-warn-photos-meta` (28cb458), highest priority:**
   - Low battery and Low Power Mode warn only, with onboarding copy to match.
   - The Photos replace path keeps albums, favourite and hidden, and trashes the original only after the copy is verified and added to its albums.
   - Finish the album, favourite and hidden carry-over with fake-store tests for each attribute, for videos and photos.
   - Update the battery tests.
   - Build App and App-iOS.
2. **`plan-10/ask-empty-reply` (45d144d):** Ask must never end a turn empty. If the retry also fails, run the tool named in the hidden text, or show the Retry card. Add the fake-model tests, then run the real-AI eval at most twice.
3. **`plan-10/tests-mac-ui` (2a78e2a). The screen is needed, so ask the owner first:**
   - A Mac `UITests` target covering every page.
   - `Apps/Shared/UITestSupport/LayoutAudit.swift`, the overlap check.
   - Reference PNGs with a pixel diff (`RECORD_SNAPSHOTS=1`).
   - `TransitionTests`, which samples element and window frames 0, 100, 250 and 500 ms after each sidebar click.
   - It started before be04853. Rebase it, then confirm the transition test passes with the fix (and fails if the fix is reverted).
4. **`plan-10/tests-ios-ui` (e80bb4f). The simulator only, but ask before any device run:**
   - The iOS copy of `LayoutAudit`. Dedupe it with the Mac branch so there is one shared file.
   - References, light and dark, at the default size and AX3.
   - Stand-ins for iCloud and Photos access states, as launch arguments.
   - UI tests for the rules.
   - `scripts/device-smoke.sh` (install, run a short flow, pull crash logs, fail on any new `Aarik-*.ips`).
   - Re-record the references after the scroll fix.

## Known gaps
- **Full `scripts/verify.sh`:** it has not been rerun since today's merges; the last run was stopped. Run `IOS_SKIP_TESTING=UITests scripts/verify.sh` first, which needs no screen.
- **Mac by eye:** confirm no window resize or content jump on page switch, and the chart axis labels with several days of data.
- **Scroll:** not yet a steady 120 Hz (about 90 fps). No Time Profiler trace was captured (the `xctrace` attach couldn't find the process).
- **Real device:** the rest of the `docs/RELEASING.md` checklist. The Live Activity after Allow and iCloud downloads are unconfirmed on the device.
- **Owner check:** with Photos' Library sort set to **Captured**, confirm a replaced video sits on its original date.

## Next
1. Finish and merge WIP 1, then WIP 2. Install on the Mac (Release to `/Applications/Aarik.app`) and the iPhone (`xcrun devicectl device install app --device 00008120-00145D840AFBC01E …`), with the owner's OK.
2. Run the verify without UI tests and fix any failures.
3. With the owner's OK on screen use, finish WIP 3 and WIP 4.
4. Offer the finishing options. Merging to `main` is the owner's call.
