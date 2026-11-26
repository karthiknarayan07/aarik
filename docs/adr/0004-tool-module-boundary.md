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
- `ConvertModule` (`Apps/macOS/Sources`) wraps today's pages. The pure part, the pages and the sidebar sections for a
  given state, is `VideoPage` and `VideoSidebar` in `Convert`, and has unit tests.
- `RootView` and `SidebarView` are generic over the module and take no tool types: the shell knows only
  `ToolModule`. What used to sit in the window for the video tool (the Replace confirmation, the loss review, the
  messages, the file importer, dropped files, the bar for originals waiting in Photos, sidebar context menus and drops,
  the menu commands) is supplied by `ConvertModule` through `dialogs`, `detail`, `contextMenu(for:)`,
  `dropFiles(_:on:)` and `commands`. `MainWindowController` is the only place that makes the module and hands it in.
  The sidebar's visibility stays the window's.
- The protocol uses SwiftUI and Foundation only, no AppKit, so the same shell can host a module in an iOS app. The
  sidebar's rows and which of them can be selected are decided by the pure `ToolSidebarModel`, which the shell calls
  and the tests exercise with a fake module.
- The shared services (queue, settings, updater, notifier) stay with the app and `AppModel`; a module is given them,
  it doesn't own them.
- Nothing visible changes: the sidebar, toolbar, inspector, menus, shortcuts, titles and Settings are as before.

## Why a boundary and not a plugin system

There is one tool and no second one planned yet. A plugin system (runtime loading, a registry of ten or twenty
entries, a settings page for tools) would be designed from imagined needs. The boundary is designed from what the
video tool needs and costs one protocol. The shell holds one module value; adding a second tool later means adding
a module and a switcher, not rewriting the window.

The module's menu commands are wired: `MainApp` adds `module.commands` to the scene.

The disabled "Soon" rows are part of the protocol for now (`Availability.comingSoon`); removing the placeholders
(Plan 9 Task 4) removes that case, its accessibility text and its tests together.

## Future direction (not built)

- A Home page shows the tools as cards.
- With a tool open, the sidebar shows that tool's own items under a small switcher at the top (for example
  "Downscale Video ▾"), with ⌘1 and ⌘2 to switch. The sidebar never goes blank and Home stays reachable.
- The video tool's Overview stays its own first page.
