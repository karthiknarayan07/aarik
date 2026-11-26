# ADR 0006: Tool core, app services and per-platform scenes

Status: Accepted (owner, 2026-11-26). Supersedes the shape of `ToolModule` in ADR 0004; ADR 0004's rule still holds ("no visible change, not a plugin system").

## Context

Aarik now ships on macOS and iOS, and more tools will follow (photo conversion, format changes). Two things make the current shape hard to grow:
- `ToolModule` has 7 associated types and about 15 members, all of them Mac-shaped.
- One `AppModel` of about 1,600 lines holds almost all the video-tool logic.

## Decision

1. **`Tool` (Core) is small and has no SwiftUI.**
   - It carries `id`, `title`, `systemImage`, `platforms: ToolPlatforms`, and `accepts(_ input: MediaInput) -> Bool`.
   - It also provides `runner(for kind: JobKind) -> JobRunner?`.
   - It is a deep module that tests cover through `swift test`.
2. **Per-platform presentation lives in each tool's UI package.**
   - The Mac uses `MacToolScene`, which takes over today's `ToolModule` members: sidebar, detail, toolbar, inspector, commands, dialogs, row menus and drops.
   - iOS uses `IOSToolScene`, which covers the tool's whole interface (`root()`), its sheets and the intent and share hand-off. The shell owns only the Tools list and the `NavigationStack` that pushes the chosen tool's `root()`; the tool brings its own tab bar and its own way back through the `toolExit` environment action. The shell holds each tool's scene as `AnyIOSToolScene` and keeps the open tool in `SceneStorage`; a tool keeps its own tab the same way.
   - Each protocol lives in Core, behind `#if os`. A tool's UI target supplies one adapter per platform it supports.
   - A shell knows only `Tool` and its own scene protocol.
3. **`AppServices` (Core) is the shared toolbox, and every tool has its own model.**
   - `AppServices` holds the job queue, the pressure coordinator, the settings store, pending deletions, staging, the library service and the Assistant client.
   - Each tool owns its own observable model, such as `ConvertModel(services:)`, which takes today's video logic out of `AppModel`.
   - There is no generic "AppState": it failed the deletion test.
   - The shell is the composition root. It builds `AppServices`, then each tool's model, then each tool's scene.
4. **There is one shared job queue.**
   - A job carries `toolID` and a Codable payload, and a tool registers its runners.
   - The speed limit, battery and heat rules, the disk reservations, the iCloud download gate, the background grant and the Live Activity all apply across every tool.
   - The queue decodes each persisted job by tool id. A job whose tool is unknown is kept untouched, not dropped.
5. **A shared library service lives in Core.** It owns Photos and Files browsing, thumbnails, limited access and iCloud-aware metadata, and it never downloads to browse. A tool asks for the media kinds it handles and adds its own badges and filters.
6. **Platform adapters sit in the Core `Platform` target.**
   - The protocols cover trash and Recently Deleted, the pressure sources, the background-execution grant, reveal and open, and the pasteboard and drag-out.
   - Each protocol has a macOS and an iOS adapter behind `#if os`, inside the adapter files only. Fakes live in `MediaTestSupport`.

## Consequences

- Adding a tool means one new package: `Tool`, a model, runners and scenes. No shared file needs editing, apart from the shell's registry line.
- `AppModel` disappears gradually. Its tool-agnostic parts move into `AppServices` and the rest into `ConvertModel`. The Mac's behaviour must not change.
- Every persisted identifier stays as it is (Plan 10's Global Constraints).
