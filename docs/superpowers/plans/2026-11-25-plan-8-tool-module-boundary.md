# Plan 8: Tool Module Boundary

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Aarik can host more tools later, each with its own sidebar, toolbar and screens, without rewriting the shell. v0.1.0 looks and behaves exactly as it does today.

**Owner decisions (2026-11-25, via question tool):**
- Build the boundary now and the multi-tool UI later: no Home page of tool cards and no tool switcher in v0.1.0.
- There is no second tool yet. Design the boundary from what the video tool needs, and don't invent features for imagined tools.

**Future direction (not built now):**
- A Home page shows the tools as cards.
- When a tool is open, the sidebar shows that tool's own items under a small switcher at the top (for example "Video Shrinker ▾"), with ⌘1/⌘2 shortcuts.
- The sidebar never goes blank, and Home stays reachable.
- The video tool's Overview stays its own first page.

## Global Constraints

- **No visible change.** Sidebar items, toolbar, inspector, menus, keyboard shortcuts, window title, Settings and every existing test and XCUITest selector behave exactly as before.
- **Not a plugin system.** There is no runtime loading, no registry of 10–20 entries and no settings UI for tools. The shell holds one tool value.
- Plan 2–7 constraints hold:
  - brand-neutral Swift
  - Swift 6 strict, zero warnings, `swift format lint --strict`
  - no third-party dependencies

## Task 1: `ToolModule` boundary (after Plan 4 Tasks 2–3 and Plan 3 Task 6 merge)

- **Shared core:** a small `@MainActor` protocol `ToolModule` in AppCore. It has:
  - an id, a title and a system image
  - `sidebar`, `detail(for:)`, `toolbar` and `inspector` view builders
  - optional `commands`
  - The shared services (queue, settings, updater, notifier) stay in the shared core and are passed in, not owned by the tool.
- **Video tool:** `VideoShrinkerModule` wraps today's sidebar sections:
  - Overview, Local files, Videos, Queue and Completed
  - their detail views, toolbar and inspector
  - no behaviour change
- **Shell:** the main window hosts the one current module through the protocol. It must not import tool-specific types beyond creating the module.
- **Tests:**
  - The module exposes the same sidebar items in the same order as before.
  - The shell renders the module's items. Use a fake module in tests.
- **ADR 0004:** a short record of why this is a boundary and not a plugin system, and the future Home/switcher direction above.
