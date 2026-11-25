# Aarik native-Mac audit (macOS 26)

Scope: App/Sources, Packages/AppModules/Sources/{AppUI,DownscaleVideo/Inspector}, plus the UI deltas of `plan-4/tasks-2-3` (AppKit `NSWindow` hosting SwiftUI, Dock/Open With/notification actions) and `plan-3/task-6` (Photos queue UI, Photos inspector). Read-only; nothing was run. APIs marked (SDK) were confirmed present in the macOS SDK swiftinterface: `safeAreaBar`, `ToolbarSpacer`, `scrollEdgeEffectStyle`, `backgroundExtensionEffect`, `.glassProminent`, `searchToolbarBehavior`, `.radioGroup`, `draggable`, `windowToolbarFullScreenVisibility`, `sharedBackgroundVisibility`. `glassEffect` is not a View method in this interface, so do not plan around hand-applied glass; use system controls and styles.

Note on copy: the brief says sentence case. Apple's Mac apps (Finder, Photos, Mail, Music) use Title Case for menu items, buttons, toolbar labels, sidebar items and column headers, and sentence case for descriptive text. N14 is written against that; owner should decide.

Priority: High = visibly non-Mac or broken convention. Medium = missing expected affordance. Low = polish.

---
## High

**N1 (High) MediaGrid is hand-built, lacks core Finder/Photos grid behaviour.**
`Packages/AppModules/Sources/AppUI/MediaGrid.swift:52-106` (ScrollView + LazyVGrid + `.onTapGesture` + custom `GridSelection`).
Missing: double-click (open / Quick Look / add to queue), Return key, marquee (rubber-band) selection, ⇧-arrow range extend, ⌘-arrow, Home/End, type-select (type a name to jump), drag-out of files, drop-target feedback, visible keyboard focus (`.focusEffectDisabled()` at :73 hides it, so full-keyboard-access users cannot see where focus is). Selection is an opaque 3 pt accent stroke (`MediaTile.swift:57-62`) that does not dim to grey when the window is inactive, unlike Finder icon view and Photos.
Apple: Finder icon view, Photos library grid, Photos selection with marquee.
Fix: wrap `NSCollectionView` in an `NSViewRepresentable` (sections, `allowsMultipleSelection`, `isSelectable`, marquee for free, `NSCollectionViewItem.isSelected` with `selectionHighlight`, `registerForDraggedTypes`, `pasteboardWriterForItemAt` returning `NSURL`, `keyDown` type-select via `NSCollectionView` + `NSEvent`), double-click via `NSClickGestureRecognizer(numberOfClicksRequired: 2)`; keep the existing `GridSelection` tests only if SwiftUI stays. Cheaper stopgap: keep SwiftUI, add `.onTapGesture(count: 2)` before the single tap, `.onKeyPress(.return)`, `.draggable(url)` on tiles, a visible focus ring (remove `.focusEffectDisabled()`, draw ring on the focused tile), and `Color(nsColor: .unemphasizedSelectedContentBackgroundColor)` via `@Environment(\.controlActiveState)` for the inactive stroke. Selected tile: use `NSColor.selectedContentBackgroundColor` fill/rounded stroke at 2 pt like Photos.

**N2 (High) Content chrome is stacked inside the detail view, not in the toolbar, so nothing scrolls under glass.**
`LocalFilesView.swift:26-72` and `PhotosView.swift:103-125`: `VStack { SavingsHeader; Divider; QualityFilterBar; Divider; grid; Divider; LibraryStatusLine }`, `QualityFilterBar.swift:11-40` (row of `.controlSize(.small)` menus), `SavingsHeader.swift:57-79`, `PhotosView PhotosHeader`.
Non-native: three hairline-separated bars around the grid. On macOS 26 the grid should extend under the transparent toolbar with the scroll-edge effect; Apple apps never ring content with Dividers.
Apple: Photos (filter is a toolbar menu, title/subtitle carry counts, grid scrolls edge to edge), Finder (Group/Sort in toolbar and View menu), Mail (filter button in sidebar/list header).
Fix: move filters to one toolbar `Menu` with a funnel icon (`Label("Filter", systemImage: "line.3.horizontal.decrease")`) containing the existing checkmark `Toggle`s grouped with `Section("Quality")`, `Section("Codec")`, etc. (the facet-count text stays), or use `.searchable` tokens/`searchScopes` for codec/range. Put the savings summary into `navigationSubtitle` (always, not only when filtered; Photos shows "N Photos, M Videos") and, if the big "Could free about X" must stay, host it with `.safeAreaBar(edge: .top)` (SDK) so the grid scrolls under it with the glass edge effect, and drop the Dividers. Replace `LibraryStatusLine` with the subtitle plus an optional View > Show Status Bar, or `.safeAreaBar(edge: .bottom)`.

**N3 (High) Main window rebuilt as bare `NSWindow` (plan-4): full screen, toolbar glass, tabs, restoration at risk.**
`plan-4/tasks-2-3: App/Sources/MainWindow.swift` (`styleMask = [.titled,.closable,.miniaturizable,.resizable]`, `hosting.sizingOptions = []`, `window.center()`, `setFrameAutosaveName("main")`).
Issues: (a) no `collectionBehavior = .fullScreenPrimary` is set; plain `NSWindow` does not get it by default, so View > Enter Full Screen and the green-button full screen are likely missing (SwiftUI `WindowGroup` sets this for you). Verify at runtime. (b) `window.toolbarStyle`/`titlebarSeparatorStyle` unset: confirm `NavigationSplitView` still gets the unified toolbar and sidebar-extends-under-titlebar glass look inside an `NSHostingController` window; no `.fullSizeContentView` is requested. (c) Only the frame is restored; selected sidebar item, inspector open state, sort and grouping are not (Photos and Finder restore all). (d) Close-hides model with `isReleasedWhenClosed = false` and `applicationShouldTerminateAfterLastWindowClosed == false` makes Window menu list nothing after close, and File > Close/⌘W and Window > "Aarik" reopen are not menu-reachable except via Dock click (Mail and Messages list their main window in Window to reopen it). (e) Settings-only `Scene` body means SwiftUI no longer supplies File > New/Close, and `LibraryCommands` anchor `.newItem` has no group to sit beside.
Apple: Photos, Mail (single main window reopened by Dock click and Window menu).
Fix: preferred, keep a SwiftUI `Window("Aarik", id: "main") { RootView }` (single-instance scene; gives full screen, restoration via `@SceneStorage`, Window-menu entry, ⌘W, toolbar glass) and open it with `@Environment(\.openWindow)` from the delegate (store an `OpenWindowAction` or use `NSApp.windows`); if AppKit must own it, set `window.collectionBehavior.insert(.fullScreenPrimary)`, `window.toolbarStyle = .unified`, `window.tabbingMode = .disallowed`, `window.isRestorable = true` + `restorationClass`, add `NSWindow.titlebarSeparatorStyle = .automatic`, and a Window-menu item `Button("Aarik") { model.showMainWindow() }` with `.keyboardShortcut("0")` via `CommandGroup(after: .windowList)`. Persist selection/inspector with `@SceneStorage` or `@AppStorage` (selection as the destination raw string).

**N4 (High) Default Help menu item is dead.**
missing: `App/Info.plist` has no `CFBundleHelpBookFolder`; no `CommandGroup(replacing: .help)`.
SwiftUI inserts "Aarik Help" with ⌘? that does nothing. Apple apps give a working Help menu with search.
Fix: either ship an Apple Help Book (`CFBundleHelpBookFolder`, `CFBundleHelpBookName`) and `NSApp.showHelp(nil)`, or replace the command: `CommandGroup(replacing: .help) { Link("Aarik Help", destination: helpURL); Link("Privacy and What Changes in Your Files", destination: ...) }`. Even a two-item custom Help is better than a disabled item; the system Help-menu search field is kept by AppKit when `NSApp.helpMenu` is set.

**N5 (High) Preset estimate "radio" rows are a custom button list inside a Form.**
`DownscaleVideo/Inspector/PresetEstimateRows.swift:34-62`: `Button(.plain)` with `checkmark.circle.fill`/`circle` imagery, manual `.isSelected` trait, hard-coded `.green` percent.
Apple: System Settings and Finder inspectors use real radio groups or popup pickers; custom circles read as iOS.
Fix: `Picker("Quality", selection: $selection) { ForEach(estimates) { Text(rowTitle).tag($0.preset) } }.pickerStyle(.radioGroup)` with each row's size and saving as trailing secondary text (use `LabeledContent` row builder or a two-column `Text` using `.monospacedDigit()`); disabled for custom via `.disabled(isCustom)`. This also gives VoiceOver radio semantics and ↑/↓ keyboard handling.

---
## Medium

**N6 (Medium) Inspector bottom action uses a custom bar background.**
`LibraryInspector.swift:49-79` (`QueueButton`: `.background(.bar)`, large full-width `.borderedProminent`, caption below) and the same in `plan-3/task-6 PhotosView.swift PhotosInspector.safeAreaInset`.
On macOS 26 an opaque `.bar` strip at the bottom of an inspector fights the glass sidebar/inspector. Xcode and Photos put the primary command in the toolbar.
Fix: add `ToolbarItem(placement: .primaryAction) { Button(model.addToQueueTitle, systemImage: "plus") {...}.keyboardShortcut(.return, modifiers: .command).buttonStyle(.glassProminent) }` (SDK) and delete the strip; keep the "Missing files are skipped" text as the `Section` footer. If a bottom button stays, drop `.background(.bar)` and use `.safeAreaBar(edge: .bottom)` so the system draws the edge effect.

**N7 (Medium) Toolbar items are not grouped for glass; grouping picker is in `.navigation`.**
`LocalFilesToolbar.swift:19-52`: segmented "Group by" in `.navigation` (reserved for back/forward and sidebar-adjacent controls), Sort and Add as loose `ToolbarItem`s, redundant `.accessibilityLabel` on a `Label`.
Apple: Photos puts the Years/Months/All segmented control in `.principal`; Finder groups view-mode, group and sort in one `ControlGroup`/menu.
Fix: `ToolbarItem(placement: .principal)` for the segmented Group by (or fold it into a View-style `Menu`), `ToolbarItemGroup(placement: .primaryAction)` for Sort and Add, `ToolbarSpacer(.fixed)` between unrelated groups and `ToolbarSpacer(.flexible)` before search (SDK). Mark `InspectorToggle` in its own group: `ToolbarItem(placement: .primaryAction) { ... }.sharedBackgroundVisibility(.hidden)` if it should not merge with the Add button.

**N8 (Medium) No Dock affordances: no Dock progress, no Dock menu, no badge.**
missing: `applicationDockMenu(_:)` absent in `AppDelegate.swift`; no `NSApp.dockTile` use anywhere.
Apple: Safari Downloads, Finder copy, Compressor/Final Cut show progress on the Dock tile; Music has transport items in the Dock menu.
Fix: in the delegate observe `model.activity.runningProgress`; set `NSApp.dockTile.contentView = NSHostingView(rootView: DockProgress(...))` (app icon plus a bottom `ProgressView(value:)`) then `dockTile.display()`, reset to nil on idle; `dockTile.badgeLabel = String(queueCount)` while queued (or leave badge to notifications). Add `func applicationDockMenu(_:) -> NSMenu?` with "Pause Queue/Resume Queue", "Add Videos…", and the current job's name as a disabled item.

**N9 (Medium) Menu bar is incomplete.**
`MainApp.swift:25-63`.
- Edit: no Undo/Redo for "Remove from library" (Photos and Finder undo removals). Fix: register with `UndoManager` (`@Environment(\.undoManager)` or `model.undoManager`) so Edit > Undo Remove from Library works.
- Edit "Remove from library" has no shown shortcut; it works on ⌫ via `onDeleteCommand` (`LocalFilesView.swift:60`) but the menu item shows none. Apple shows ⌘⌫ in the menu (Finder "Move to Trash"). Fix: `.keyboardShortcut(.delete, modifiers: .command)` on the menu button.
- View: only SidebarCommands/InspectorCommands. Missing "Group By" (Years/Months/None) and "Sort By" submenus (Finder View > Group By/Sort By), "Show Filters", and, for N3, Enter Full Screen. Fix: `CommandMenu`/`CommandGroup(after: .toolbar)` with `Picker("Group By", selection:)` rendered as a menu section with checkmarks.
- Go/navigation: no ⌘1…⌘7 for sidebar sections (Photos uses ⌘1-⌘4 for tabs). Fix: `CommandGroup(before: .sidebar)` or a "Go" menu with `Button("Queue") { model.selection = .queue }.keyboardShortcut("4")`.
- Queue menu: Pause/Resume bound to ⌘. conflicts with the system "Cancel/Stop" convention (Escape/⌘.); Music uses Space for play/pause. Use ⌥⌘P or no shortcut. Queue menu is missing "Cancel All…" (`…` because of its confirmation dialog), "Retry All Failed", "Show in Finder". `CommandMenu("Queue")` is fine as a custom menu (like Music's Controls).
- File: no "Open Recent" is fine, but "Add files…" should be "Add Videos…" or "Open…" (⌘O is "Open"); add "Show in Finder" (⌘R) and "Quick Look" (⌘Y; space) as menu items so they are discoverable, plus Share.

**N10 (Medium) No Share, Services, or drag-out.**
missing across `OutcomeLists.swift:36-70`, `LocalFilesView.swift TileMenu`, `Info.plist` (no `NSServices`).
Apple: Finder/Photos/Music all have a Share menu and drag files out.
Fix: `ShareLink(item: outcome.output)` in the Completed row context menu and a toolbar `ShareLink` for the selection; `.draggable(outcome.output)` on Completed rows and tiles (`.draggable(item.fileURL)`), and for Photos videos a `Transferable` wrapper exporting the original via PhotoKit when dragged out only if cheap (otherwise omit). Add an `NSServices` entry ("Convert with Aarik" for public.movie, `NSSendFileTypes`) wired through the existing `application(_:open:)` quick-run path from plan-4, and a Finder Quick Action/`NSExtension` later.

**N11 (Medium) Outcome lists are plain `List` rows with per-row icon buttons and no context menus or selection.**
`OutcomeLists.swift:12-39,48-60,64-80,130-148`, `QueueView.swift:12-25,49-87`, `JobDisplay.swift:79-93`.
Missing: row selection (⌘/⇧-click, ⌘A), right-click menus (Show in Finder, Share, Quick Look, Retry, Remove), double-click opens/reveals, Space to Quick Look, ⌫ to remove from queue or dismiss, reordering in the Queue (`.onMove`), sortable columns. Rows have bare `Button(.borderless)` icons beside each item (`ShowInFinderButton`, cancel `xmark.circle.fill`), which is the iOS inline-trailing-button pattern.
Apple: Safari Downloads, Finder list view, Mail message list.
Fix: `List(selection:)` with `.contextMenu(forSelectionType:menu:primaryAction:)` (double-click/Return = Show in Finder or Quick Look), `.onDeleteCommand`, `.onMove` for the queue, `.quickLookPreview`. For Completed, use `Table` with columns Name, Before, After, Saved, Date and `.tableStyle(.inset(alternatesRowBackgrounds: true))`. Keep the inline icon only for the running job's cancel (like Safari's x).

**N12 (Medium) Photos videos lack Quick Look and Show-in-Photos; space bar does nothing there.**
`plan-2 PhotosView.swift:140`: `MediaGrid(... onSpace: {})`; `PhotoTileMenu` has a single "Add to queue".
Apple: Photos supports Space-to-preview, and Finder-like menus. Fix: for Photos assets, either preview the already-cached thumbnail/poster via `quickLookPreview` on a temp file or hide Space; add "Reveal in Photos" with `PHAsset` identifier + `NSWorkspace.open(URL("photos://asset?uuid=..."))` if available (verify). Do not leave a silent no-op.

**N13 (Medium) Orange/green text for status is small and low-contrast.**
`.foregroundStyle(.orange)` on 11-12 pt text: `LibraryInspector.swift:93`, `LossConfirmationSheet.swift:62`, `SettingsView.swift:132`, `LocalFilesView.swift:76,164`, `DownscaleInspector.swift` (`.green`, `.orange`), `PresetEstimateRows.swift:44`, `AdvancedSettingsView.swift:56`, `ActivityList.swift ReportBadge`. Orange caption on white is below 3:1; with Increase Contrast on it still fails. Apple uses `.secondary` text with a coloured SF Symbol, or `.primary` text for warnings.
Fix: keep colour on the symbol only: `Label { Text(msg).foregroundStyle(.secondary) } icon: { Image(systemName:...).foregroundStyle(.orange) }`. Use `.tint`/`.green` only for large text or glyphs. Replace "Could free about" green row with `.primary`.

**N14 (Medium) Capitalisation and ellipsis conventions differ from Apple's apps.**
Menu items, buttons and sidebar titles are sentence case: "Add files…", "Remove from library", "Pause queue", "Add to queue", "Local files", "Kept as is", "Cancel all", "Retry all", "Show in Finder" (this one is right), "Open Photos settings", "Clear filters", "Convert anyway", "Check Now" (mixed).
Apple Mac apps use Title Case for menu items, buttons and sidebar items: "Add to Album", "Show in Finder", "Move to Trash", "Check for Updates…". Ellipsis audit: "Add files" toolbar button label lacks the `…` in its accessibility label (`LocalFilesToolbar.swift:24`); "Cancel all" opens a confirmation, so it should be "Cancel All…" (HIG: ellipsis when more input is needed; confirmations that only confirm do not require one, so verify intent); "Change…" is right; "Allow access to Photos…" is right; "Open Full Disk Access" should be "Open System Settings…".
Fix: one pass of copy to Title Case for controls, keep sentence case for descriptions. If owner insists on sentence case, record that in the design doc as a deliberate deviation. Also "Open Photos settings" should be "Open System Settings…" (the app is named System Settings).

**N15 (Medium) Sidebar contains disabled "Soon" placeholders and an unlabeled Tools section.**
`SidebarView.swift:25-32,75-91`, `SidebarDestination.swift emptyState` for `.overview` ("Coming with Photos") and `.tool`.
Apple does not ship disabled stub items (Mail/Photos show only working destinations). Fix: hide `comingSoonTools` and the Overview placeholder until they exist; hide empty "Tools" section when only one tool. Make sections collapsible: `Section("Library", isExpanded: $expanded)` and persist via `@SceneStorage`.

**N16 (Medium) Two different welcome/empty designs; custom large welcome on Overview.**
`WelcomeView.swift:11-57` (140 pt brand mark, `.largeTitle.weight(.semibold)`, three Labels, large prominent button, hard-coded `maxWidth: 460`, `frame(height: 140)`) vs `LocalFilesWelcome`/`WelcomeState` (ContentUnavailableView).
Fix: render Overview as one `ContentUnavailableView` (like Photos' empty library) with the three promises as the description; keep the brand mark as the Label image only if it is an SF Symbol-style template. Remove hard-coded sizes and `.font(.largeTitle.weight)`.

**N17 (Medium) Hard-coded sizes and fonts.**
`MainApp.swift:11` `frame(minWidth: 900, minHeight: 600)`, `SettingsView.swift:17` `.frame(width: 480)`, `MediaGrid.swift:23-26,119` spacing 12/padding 16, `MediaTile.swift:34,57` fixed 4:3, 3 pt stroke, `-4` padding, `LossConfirmationSheet.swift:33` `width: 460`, `ReportPopover width: 340`, `SavingsHeader.swift` `.title2.weight(.semibold)`, `.padding(.horizontal, 16)`, QualityFilterBar `.controlSize(.small)`. Fix: use `.frame(minWidth:)` only for window mins (acceptable), express others via `ScaledMetric`, `.formStyle(.grouped)` auto sizing for Settings (`.fixedSize` already, drop the explicit 480 or use `.frame(minWidth: 450)`), text styles (`.title3`, `.headline`) without weight overrides, and system spacing (`.padding()` default 16 is fine) so Dynamic Type/larger text settings work. Tile aspect ratio is acceptable.

**N18 (Medium) Search prompt and behaviour.**
`LocalFilesView.swift:67`, `PhotosView.swift:120`: prompt "Search by name" and `placement: .toolbar`. Apple apps use "Search" (Photos: "Search"); on macOS 26 use `.searchToolbarBehavior(.minimize)` (SDK) where space is tight (Photos collapses search into a button) and add `.searchScopes`/tokens if filter becomes search tokens (N2). ⌘F already works.

---
## Low

**N19 (Low) Alerts and dialogs.**
`RootView.swift:61-76`: info alert uses `Button("OK", role: .cancel)`; role `.cancel` renders without the default (blue) style; Apple uses plain "OK" as default for informational alerts. The "Replace the original?" alert (`:61`) is not destructive (originals go to Trash, recoverable), so styling Replace `role: .destructive` over-warns versus Finder "Replace" dialogs; keep `.destructive` only if the Trash move is irrecoverable (keep-originals off and Photos Recently Deleted may still count). Message should lead with consequences ("The original moves to the Trash after..."), title Title Case "Replace the Original?". Use `.alert(... presenting:)` already; add `.dialogSeverity(.critical)` only for loss.
`LossConfirmationSheet.swift`: long custom sheet with orange text; consider `Form`/grouped list and `.presentationSizing(.form)` (SDK-available) instead of `.padding(20).frame(width:460)`.
`QueueView.swift:34` confirmation "Cancel all conversions?" with buttons "Cancel all"/"Keep converting": the dialog's Cancel role button reads as "Keep converting" which is good; rename destructive to "Cancel All Conversions". Apple Mac uses `.alert`/sheet for confirmations, not an iOS-style action sheet: on macOS `confirmationDialog` renders as an alert, so this is fine.

**N20 (Low) Window title/subtitle consistency.**
`navigationTitle` set per view but `RootView` fallback `AppModel.displayName`; subtitle only appears when filtered (`LocalFilesView.swift:81`) or Paused. Apple shows counts always (Photos "1,234 Photos"). Show `VideoCount.summary` always and drop the bottom status line (N2).

**N21 (Low) Settings details.**
`SettingsView.swift`: structure is right (TabView with `Tab`, grouped Forms). Polish: `LabeledContent("Look for a new version now") { Button("Check Now") }` becomes a plain `Button("Check for Updates…")` aligned with the Toggle; "Start the queue automatically" subtitle text as a Section footer or `Text` with `.foregroundStyle(.secondary).font(.caption)` is fine; add `.scenePadding()`; `FolderRow` should be a `LabeledContent("Folder") { Text(path); Button("Choose…") }` (Choose with an ellipsis, like Finder). Add Settings > "Notifications" link to System Settings.

**N22 (Low) Hand-made progress/gauge.**
`SavingsHeader.swift:96-107 SavingsBar` (Capsule fill) and sidebar `ProgressView(value:).circular .mini` (`SidebarView.swift:44`). Use `ProgressView(value: fraction).progressViewStyle(.linear)` or `Gauge(value:)` `.gaugeStyle(.linearCapacity)` for the savings bar; keep the sidebar ring (Mail's sync, Music) but label via `accessibilityValue` rather than hiding children (`SidebarView.swift:53-54` uses `.accessibilityElement(children: .ignore)` plus hand-built text).

**N23 (Low) Tile overlays force dark scheme.**
`MediaTile.swift:85-92`: `.thinMaterial` with `.environment(\.colorScheme, .dark)`. Acceptable on top of imagery (Photos does similar), but `.foregroundStyle(.primary)` after forced dark is brittle; use `.white` plus `.shadow` or `.ultraThinMaterial` and `.regularMaterial` per Reduce Transparency; test with Reduce Transparency and Increase Contrast (materials fall back automatically; the dark forcing is the only hand-set colour).

**N24 (Low) Pinned section header background.**
`MediaGrid.swift:149`: `.background(.background)` on `pinnedViews` header paints an opaque band that defeats the toolbar scroll edge. Use `.background(.regularMaterial)` or no background and rely on `.scrollEdgeEffectStyle(.soft, for: .top)` (SDK). Photos uses a translucent date header.

**N25 (Low) Inspector layout nits.**
`DownscaleInspector.swift`: caption `Text` hints inside Form sections should be `Section { } footer: { Text }` (`PhotosInspector` and `AdvancedSettingsView.swift:30-40`); bit-rate `TextField` with unit inside the label (`"Bit rate (Mbps)"`) should be `LabeledContent("Bit rate") { TextField("", value:...).labelsHidden(); Text("Mbps") }` or a `Stepper`; `.inspectorColumnWidth(min: 260, ideal: 300, max: 420)` fine. Inspector empty states `EmptyState(... "rectangle.dashed")` is standard.

**N26 (Low) Notifications.**
`QueueNotifier.swift`: authorisation requested on first enqueue (good, contextual). Add `.timeSensitive` no; but include an action "Show in Finder"/"Show Queue" (plan-4 adds a category for quick runs only) and set `content.threadIdentifier`, `content.sound = .default`. Request `.badge` if the Dock badge (N8) is added.

**N27 (Low) Sidebar item context menu and navigation.**
No right-click on sidebar rows (e.g. "Add Videos…", "Remove from Library" for Local files; Mail's folders have menus), no `.dropDestination` on the "Local files" row (drag videos onto sidebar item adds them). The root `.dropDestination(for: URL.self)` on `RootView.swift:57` accepts but gives no highlight; use `.dropDestination(for:isTargeted:)` and `.overlay` a system `RoundedRectangle().strokeBorder(.tint)`.

**N28 (Low) Reduce motion.** No custom animations found; keep it that way. `ProgressView` is system. No action.

---
## Already native, keep
- `NavigationSplitView` with `List(selection:)` sidebar, `Section`s, `Label`, `.badge`, `.navigationSplitViewColumnWidth` (`SidebarView.swift`, `RootView.swift`).
- `.inspector(isPresented:)` with `.inspectorColumnWidth` and `InspectorCommands`/`SidebarCommands` for View menu items.
- `Settings` scene with `TabView`/`Tab`, `Form` + `.formStyle(.grouped)`, `Picker`, `Toggle` with secondary description, `@AppStorage`.
- `.searchable(placement: .toolbar)`, `ContentUnavailableView` (including `.search(text:)`) for empty states, `navigationTitle`/`navigationSubtitle`.
- `.quickLookPreview` with Space on the local grid; Show in Finder via `activateFileViewerSelecting`; `fileImporter` for open panels; `UNUserNotificationCenter` with contextual authorisation and suppression while frontmost.
- Grid keyboard model: ⌘A through `onCommand(selectAll(_:))` and responder chain, ⌘/⇧-click, arrow keys, context menus that act on selection-when-clicked-in-selection (Finder behaviour).
- Menu structure: `Check for Updates…` after About, `CommandMenu("Queue")`, ⌘O, ⌘⏎.
- SF Symbols throughout, `.tint`/accent colours, semantic styles (`.secondary`, `.quaternary`, `.bar` in the inspector aside from N6), real `Menu`/`Toggle` checkmark filters, plain-wording copy, truncation `.middle` on filenames, thorough VoiceOver labels on rows and tiles.
- Plan-4 behaviour that matches Mac conventions: Dock-click reopen (`applicationShouldHandleReopen`), `application(_:open:)` for Dock drop/Open With, `CFBundleDocumentTypes` with `Alternate` rank, frame autosave name, notification response routing, `applicationShouldTerminate` with `.terminateLater`.
- Plan-3 Photos queue UI: `Picker` with `Preset` + "Mixed", `fileImporter` for folder, `Change…` button, Show-in-Finder hidden for Photos outputs.
