# Continuation prompt: Aarik final test pass and polish (paste into a new agent)

You are continuing work on Aarik. Your working directory is `/Users/karthiknarayan/Developer/personal/aarik`, on the integration branch `plan-2-app-shell`, which tracks `origin/plan-2-app-shell`.

## Read first
- `AGENTS.md`.
- The memory index `~/.claude/projects/-Users-karthiknarayan-Developer-personal-aarik/memory/MEMORY.md`. It covers:
  - orchestrating Sonnet subagents
  - native first, and the design direction
  - token-lean working
  - pushing after every commit
  - asking via the question tool
- The ledger `.superpowers/sdd/2026-11-26-plan-10-ios-and-convert/progress.md`. It holds every ruling and owner decision.
- `docs/superpowers/plans/2026-11-26-plan-10-ios-and-convert.md`, `docs/adr/0006-tool-core-services-and-scenes.md` (amended for the iOS root tabs), and `docs/RELEASING.md` (the real-device checklist).

## Owner rules
- Run at most 3 parallel subagents.
- Product code comes first. The tests are a final separate pass, which is now under way.
- Stop gracefully at about 70–80% of the 5-hour usage window, and update this prompt when you do.
- Push `plan-2-app-shell` after every merge. Never push to or merge into `main`.
- Code stays brand-neutral. Never touch the owner's real Photos library. Never commit personal media or `docs/references/KeepFeather/`.
- Focus on iPhone. iPad and Duo are deferred until there are more tools.

## Merged and pushed (2026-11-26)
- Plan 10 Tasks 1–13: the Apps/ layout, Core and Convert packages, compression, the iOS app, background running with a Live Activity, share sheet and intent, widget and Control, Replace originals, the Mac polish pass, the test speed fix, iPhone UI tests and the release checklist.
- Mac redesign rounds 1 and 2:
  - Overview built on Swift Charts, backed by a SwiftData `SavingsStatsCache`.
  - Stable window size: the cause was pages without toolbar items, which made the title bar shorter.
  - Queue, Completed, Library with a storage bar, inspector, compare slider, menu bar popover and motion.
- iPhone redesign:
  - Native root tabs: Home, Browse (tool cards), Ask (hidden without Apple Intelligence) and Search.
  - Convert opens as a pushed stack: Photos, Files, Queue, Completed.
  - Select mode, onboarding, haptics and zoom transitions.
- iOS hand-off routing: share and intent hand-offs open Browse, then Convert, then Queue.
- The on-device AI Assistant: an Ask tab with streaming replies, tool calls, confirmation cards before any action, and SwiftData history. DEBUG `-AssistantDemo` runs it on a fake model.
- **Confirmed:** the real Apple Intelligence model works in the iOS Simulator. On iPhone Air `F38FA01E-D51C-4314-8A60-6F63B8DBBD27` (iOS 27.2), the Ask tab appears about a minute after boot.

## In flight when this prompt was written (check their branches; resume or redo)
- `plan-10/final-ui`: make all iPhone UI tests pass on iPhone 17 (`D1013D0D-80AF-4106-A440-2CC70A3B8B0E`), add new tests, and take final screenshots in `.superpowers/.../final-shots/`.
- `plan-10/final-unit`: run `scripts/verify.sh`, add missing unit tests (the assistant tools, Reduce Motion, the hand-off route, the zero-value chart cache, and the `#expect` main-actor warnings), then get `verify.sh --repeat 2` green twice.
- `plan-10/real-ai-smoke`: `RealAssistantSmokeTests`, gated by `RUN_REAL_AI=1`. It drives the real model on iPhone Air: streaming, a tool-call row, and Cancel on the confirmation card queueing nothing.

## Known gaps
- **Real device:** the `docs/RELEASING.md` checklist (background grant, Live Activity, battery and heat, the share-sheet notification, the widget, Replace originals on test assets).
- **Mac, by eye:** the Overview chart axis labels, the toolbar, and sidebar colours on a selected row. Mac screenshots can't be captured while the screen is locked; use the `ImageRenderer` tests (env `APP_MAC_SHOTS`).
- **Mac Convert tests:** the compress4K fixture tests stall under heavy load. Rerun them on a quiet Mac.
- **Queue throughput chart:** it is bucketed by the day each video was added, because jobs have no finish time.
- **iPad and Duo:** deferred. The scratch simulators `nav-phone` and `nav-pad` can be deleted.

## Next
1. Merge the three final-pass branches once they are green, then push.
2. Run `scripts/verify.sh --repeat 2` on `plan-2-app-shell`, then push.
3. Send the owner the final iPhone and Mac screenshots.
4. Offer the finishing options. Merging to `main` is the owner's call.
