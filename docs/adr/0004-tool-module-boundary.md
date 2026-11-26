# ADR 0004: A tool module boundary, not a plugin system

Status: **Accepted**

## Context

The app's first tool shrinks iPhone 4K video. More tools may follow, each with its own sidebar, toolbar and screens.
Until now the window knew the video tool's types directly: the sidebar, the page switch, the inspector and the
inspector toggle were all written against `SidebarDestination` and `AppModel`.

## Decision

- `ToolModule` (`AppCore/Tools/ToolModule.swift`) is a small `@MainActor` protocol. A module has an id, a title and
  a system image, and gives the shell its sidebar, `detail(for:)`, `toolbar(for:)`, `inspector(for:)` and optional
  menu commands. Its sidebar is data (`ToolSidebarSection`, `ToolSidebarItem`) that the shell draws, so the rows,
  their order, counts and VoiceOver text are testable without a UI.
- `VideoShrinkerModule` (`App/Sources`) wraps today's pages. The pure part, the pages and the sidebar sections for a
  given state, is `VideoPage` and `VideoSidebar` in `DownscaleVideo`, and has unit tests.
- `RootView` is generic over the module. It creates nothing tool-specific: `MainWindowController` makes the one
  module and hands it in. The shared services (queue, settings, updater, notifier, the importer, drops and alerts)
  stay with the shell and `AppModel`; a module is given them, it doesn't own them.
- Nothing visible changes: the sidebar, toolbar, inspector, menus, shortcuts, titles and Settings are as before.

## Why a boundary and not a plugin system

There is one tool and no second one planned yet. A plugin system (runtime loading, a registry of ten or twenty
entries, a settings page for tools) would be designed from imagined needs. The boundary is designed from what the
video tool needs and costs one protocol. The shell holds one module value; adding a second tool later means adding
a module and a switcher, not rewriting the window.

Menu commands are in the protocol (`commands`) but the app's `Commands` still live in `MainApp`; wiring a module's
commands in waits until a second tool needs them.

## Future direction (not built)

- A Home page shows the tools as cards.
- With a tool open, the sidebar shows that tool's own items under a small switcher at the top (for example
  "Downscale Video ▾"), with ⌘1 and ⌘2 to switch. The sidebar never goes blank and Home stays reachable.
- The video tool's Overview stays its own first page.
