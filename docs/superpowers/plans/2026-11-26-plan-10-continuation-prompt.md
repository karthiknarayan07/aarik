# Continuation prompt: Plan 10 base gate (paste into a new agent)

You are continuing work on Aarik. Your working directory is `/Users/karthiknarayan/Developer/personal/aarik`, on the integration branch `plan-2-app-shell`, which tracks origin.

## Read first
- `AGENTS.md`.
- The project memory in `~/.claude/projects/-Users-karthiknarayan-Developer-personal-aarik/memory/MEMORY.md`. The rules that bind you:
  - orchestrate with Sonnet subagents
  - native first
  - token-lean
  - push after every commit
  - ask via the question tool
- `docs/superpowers/plans/2026-11-26-plan-10-ios-and-convert.md`, especially the Global Constraints, the Base gate and Task 3b.
- `docs/superpowers/specs/2026-11-26-ios-and-convert-design.md`.
- `docs/adr/0006-tool-core-services-and-scenes.md`.
- The ledger at `.superpowers/sdd/2026-11-26-plan-10-ios-and-convert/progress.md`, which holds every ruling so far.

## Where things stand (2026-11-26)
- **Merged and pushed** to `plan-2-app-shell`:
  - the restructure: `Apps/macOS`, `Apps/iOS`, `App.xcworkspace`, `Packages/Core`, `Packages/Tools/Convert`, the Convert rename and brand-neutral names
  - the iOS skeleton
  - `scripts/verify.sh` with an iOS job in CI
  - the research notes
  - ADRs 0005 (proposed) and 0006
- **Paused** with work-in-progress commits. Each one may not build, and its report sits in the agent worktree at `.superpowers/sdd/2026-11-26-plan-10-ios-and-convert/`:
  - **`plan-10/task-3b`**, worktree `.claude/worktrees/agent-ae5122a58cc520ec4`. This is the `AppModel` split from ADR 0006:
    - `AppServices` in Core and `ConvertModel` in Convert
    - `ConvertMacScene: MacToolScene` in ConvertUI, with the Mac shell as the composition root
    - the tool title becomes "Convert"
  - **`plan-10/task-4`**, worktree `.claude/worktrees/agent-a5e52f4c0ef9e45c8`. This makes the packages iOS-ready:
    - `.iOS(.v26)`, with Platform seams and adapters for iOS and fakes
    - the Low Power Mode one-slot rule
    - it started on the old layout and was moving onto the new one
- **Simulators:** iPhone 17 Pro and iPad Pro 11-inch on iOS 26.5, plus the "iPhone Duo" on iOS 27.1 (UDID `AD2B36CE-232D-4240-9D6C-EFBA6367C0D3`). Always pick a simulator by UDID.
- Known flaky-under-load tests: EngineRobustnessTests, sixtyToThirty, estimateWithinRange and cancelRemovesPartialOutput. Rerun them on their own before treating a failure as real.

## Next steps (base gate first; the owner said no feature work before it)
1. Resume each paused branch with one Sonnet agent apiece (`model: sonnet`, `isolation: worktree`). Each agent reads its report, finishes the task, and merges the latest `plan-2-app-shell` into its branch.
2. Merge Task 3b first, then Task 4, with no review pass (an owner ruling under low usage). `scripts/verify.sh` must pass. Push after each merge.
3. Run `scripts/verify.sh --repeat 2` and get two green runs. That is the base gate. Mark it in the ledger and push.
4. Then fan out Phase 3 in parallel on both platforms: Tasks 5 to 12 of Plan 10, with Task 13 at the end. Keep briefs short: extract each one with `bash ~/.claude/skills/subagent-driven-development/scripts/task-brief <plan> <N>`.

## Rules that carry over
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Push `plan-2-app-shell` after every commit. Never push to `main` and never merge into `main`: that is the owner's decision.
- Never delete or overwrite user files. Never touch the owner's real Photos library.
- Ask before permanently deleting anything.
