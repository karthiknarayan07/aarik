# Plan 9 — Native Mac Polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Aarik looks and behaves like Apple's own Mac apps on macOS 26. This plan closes the gaps found by the native audit.

**Owner rule (2026-11-25):** "I want my app to be as native as possible."

**Source:** [docs/audits/2026-11-25-native-mac-audit.md](../../audits/2026-11-25-native-mac-audit.md) (N1–N28). Each task names its findings, and the audit has the file:line, the Apple example and the fix. The audit was read-only and no runtime check was done, so verify each finding against the current code before fixing it.

## Rulings (controller, 2026-11-25)

- **N14 capitalisation:** follow Apple's Mac apps.
  - Title Case for menu items, buttons, toolbar labels, sidebar items, column headers, window titles and sheet titles.
  - Sentence case for descriptive text, alert informative text, notification bodies, help text and status lines.
  - An ellipsis goes on controls that open further input (HIG).
  - "Open System Settings…" is the name for any link to System Settings.
- **N15:** no disabled "Soon" placeholders and no single-item "Tools" section. Show only working destinations, like Mail and Photos.
- **N16 / Overview:** Plan 3 Task 7 replaces the Overview welcome with the dashboard. Its empty state is one `ContentUnavailableView`, with no custom hero or hard-coded sizes.
- **AI chips (Plan 7 Task 1):** the filters from "Ask in plain words" are system search tokens (`searchable(text:tokens:)`), not custom chips, the way Mail and Photos show search tokens.
- **No hand-applied glass.** Use system controls, toolbar items and `.glassProminent` / `safeAreaBar` / `ToolbarSpacer` where the audit names them. These APIs are confirmed in the SDK; `glassEffect` is not available as a View method.

## Global Constraints

- Owner rule: as native as possible. Prefer the system control, the system behaviour and the Apple app precedent every time.
- No behaviour regressions. Every existing unit test passes, and XCUITest selectors are updated in the same task if labels change.
- Accessibility:
  - VoiceOver labels on every control
  - full keyboard access
  - Increase Contrast, Reduce Transparency and larger text all work
- Plan 2–8 constraints hold:
  - brand-neutral Swift
  - Swift 6 strict, zero warnings, `swift format lint --strict`
  - no third-party dependencies
  - never delete or overwrite user files

## Order

Runs after Plan 3 Task 7, Plan 4 Tasks 2–7, Plan 7 Tasks 1–2 and Plan 8 merge, since they touch the same views. Tasks 1–3 touch different files and can run in parallel. Task 4 runs last.

### Task 1: Window, menus and Dock
- **Findings:**
  - N3 (whatever is left after Plan 4 fix round 2)
  - N4: Help menu, using the README FAQ via a help book or a Help menu item that opens the online README
  - N8: Dock progress, Dock menu (Pause/Resume, Open Queue) and badge for waiting jobs
  - N9: menu bar completeness. Undo for remove from library, Group By/Sort By in View, ⌘1–⌘n section shortcuts, and Pause off ⌘. (use ⌥⌘P or Apple's precedent)
  - N20: title and subtitle
  - N26: notifications
- **Tests:** the menu model (pure command list) and Dock badge counts.

### Task 2: Library browser (grid, toolbar, search)
- **Findings:**
  - N1: the grid behaves like Finder and Photos. Double-click and Return open, marquee selection, type-select, drag-out with `draggable`, a focus ring, and selection that turns grey in an inactive window.
  - N2: filters and counts move into the toolbar and subtitle (`safeAreaBar`)
  - N7: toolbar grouping
  - N10: Share and drag-out
  - N12: Quick Look and Show in Photos for Photos videos
  - N17: browser sizes
  - N18: search prompt "Search" and `searchToolbarBehavior`
  - N23, N24
- **Tests:** selection model, keyboard handling and drag payloads.

### Task 3: Lists, inspector, sheets and Settings
- **Findings:**
  - N5: `Picker` `.radioGroup` for presets
  - N6: inspector action in the toolbar, `.glassProminent`, ⌘⏎
  - N11: Queue, Completed and Failed use `List(selection:)` or `Table` with `contextMenu(forSelectionType:)`, double-click and Delete
  - N13: status colour on the symbol only
  - N17: sheet and popover sizes
  - N19, N21, N22, N25, N27
- **Tests:** list selection actions and context-menu command availability.

### Task 4: Copy and sidebar pass (last)
- **Findings:** N14 per the ruling above, across every user-visible string; N15; and any copy left over from Tasks 1–3.
- **Tests and docs:** XCUITest selectors and README screenshots or wording are updated to the new labels.
- **Final check:** a manual check with VoiceOver, full keyboard access, Increase Contrast and the largest text size.
