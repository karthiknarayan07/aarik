# Plan 4 research: quick-run entry points (Finder, Shortcuts, menu bar, Dock, notifications)

Date: 2026-11-25. Target: macOS 26, Swift 6, ad-hoc signed, installed in /Applications.
Requirements: spec §8.1, §8.5a (convert in background with saved defaults, skip lossy files, one shared queue, notification opens app with skipped files queued), §9 menu bar, §13.

Confidence legend: [doc] = read on Apple docs this session; [forum] = Apple forum/DTS or third-party report found this session; [exp] = my background knowledge, NOT verified in this session. Every [exp] item needs a 15-minute spike on a real ad-hoc build before Plan 4 commits to it.

## Summary of recommendations

| Entry point | Recommendation |
|---|---|
| Finder right-click | App Intent (in the main app target) used as a Shortcuts "Quick Action" is the primary path. Fallback: NSServices entry in the main app. Skip Finder Sync and Action Extensions. |
| Shortcuts | App Intents in the main app, `supportedModes = .background`, file-in/file-out, enqueue into the in-process shared queue. |
| Menu bar | `MenuBarExtra(.window)` for UI and progress; file drops on the status icon need an AppKit `NSStatusItem` button (or MenuBarExtraAccess to reach it). Drops inside the window work with SwiftUI. |
| Dock drop | `CFBundleDocumentTypes` (Viewer, Alternate) + `application(_:open:)` via `@NSApplicationDelegateAdaptor`. |
| Notifications | `UNUserNotificationCenter` works with an ad-hoc signed bundle; action buttons via a registered category. |

The spec's own escape hatch (§8.5a "Shipping") applies: if Finder/Shortcuts are flaky unsigned, move them to the first signed release. Dock, window, menu bar, notifications do not depend on a Developer ID.

## 1. Finder right-click on one or many videos

### Comparison

(a) App Intents surfaced via Shortcuts "Use as Quick Action" (Finder).
- Mechanism: the app ships an `AppIntent` taking `[IntentFile]`. The user (or the app via an AppShortcut) wraps it in a shortcut and enables "Use as Quick Action" with "Finder" selected; it then appears under right-click > Quick Actions with the selection as input. [forum] (third-party tutorials describe the toggle and file-type filter: https://flaviocopes.com/courses/automate-macos/build-a-finder-quick-action/).
- Important limit: Apple's `AppShortcutsProvider` phrases are for Siri/Spotlight; Finder Quick Actions come from user-created shortcuts in Shortcuts.app (details pane > Use as Quick Action), not automatically from the AppShortcut. [exp] So the app cannot self-install a Finder menu item; it must ship a one-click "Add to Finder" helper (see below). I found no Apple doc saying App Shortcuts auto-appear in the Finder Quick Actions menu.
- Unsigned/ad-hoc: App Intents metadata is extracted at build time (`Metadata.appintents` in the bundle) and indexed by LaunchServices/`siriactionsd` when the app is registered, so ad-hoc signing normally works for local installs. [exp] Forum reports show intents sometimes not appearing in macOS Shortcuts (https://developer.apple.com/forums/thread/743121), usually a build/registration issue (stale DerivedData, app not in /Applications, never launched).
- Registration: launch the app once from /Applications; if actions are missing, `lsregister -f /Applications/<App>.app` then relaunch Shortcuts.app. No pluginkit step (no extension). [exp]
- Headless + shared queue: yes. Intent in the main app target runs in the app's own process (launching it in the background if needed) so it can call straight into the single JobQueue. This satisfies the "one shared queue" rule with no IPC.
- Tahoe note: `supportedModes` is the macOS 26 replacement for `openAppWhenRun` [doc] (https://developer.apple.com/documentation/appintents/intentmodes.md; DTS says openAppWhenRun is superseded: https://developer.apple.com/forums/thread/804015).

(b) Action Extension (`com.apple.ui-services`) / Finder Sync.
- Finder Sync: only monitors folders you register, was never meant to cover every file; broke on Sequoia 15.0 beta, and there are late-2025/2026 reports of it failing to load on Tahoe 26.1 ARM (extension flagged "!" in pluginkit, host never starts). [forum] https://developer.apple.com/forums/thread/756711 , https://developer.apple.com/forums/thread/806607 . Must be enabled by the user in System Settings > Login Items & Extensions > Finder.
- Action extension: appears in Quick Actions only after the user enables it in System Settings > Extensions > Finder. Needs `pluginkit -a`/launch to register. Runs in a sandboxed extension process, so it needs an IPC/XPC or app-group hand-off to the main app's queue (more code, sandbox + app group entitlements; app groups under ad-hoc signing are fragile because team-prefixed group IDs need a team). [exp]
- Verdict: highest effort, worst unsigned story, extra process.

(c) Services menu (`NSServices` in Info.plist).
- Declares `NSMessage` (handler selector), `NSSendFileTypes` (UTIs `public.movie`/`com.apple.quicktime-movie`/`public.mpeg-4`), `NSMenuItem`. Shows under right-click > Services (Finder) and the Finder menu. The handler runs in the main app process, receives an NSPasteboard of file URLs, so it can enqueue into the shared queue. [exp]
- Works for ad-hoc apps in /Applications after LaunchServices registers them; `/System/Library/CoreServices/pbs -flush` refreshes the cache; user can toggle in System Settings > Keyboard > Keyboard Shortcuts > Services. [exp]
- Downsides: buried under a "Services" submenu in newer Finder, and Apple has de-emphasized it in favor of Quick Actions; the app is launched (can stay `LSUIElement`-like no window) to receive it.

### Recommendation
Build (a) as the primary, because the Shortcuts intent in item 2 is needed anyway, so Finder costs almost nothing extra: one intent, one code path. Add (c) NSServices as a cheap, extension-free second route that works without the user touching Shortcuts (about 40 lines of Swift + one Info.plist block). Do not build (b). Because (a) needs the user to enable a Quick Action, ship a Settings button "Add to Finder right-click menu" that opens Shortcuts / explains steps (programmatic creation of a shortcut file needs a signed `.shortcut`; unsigned import is blocked, so do it via instructions or a `shortcuts://` URL). [exp]

NSServices snippet:
```xml
<key>NSServices</key><array><dict>
  <key>NSMenuItem</key><dict><key>default</key><string>Downscale videos</string></dict>
  <key>NSMessage</key><string>downscaleFiles</string>
  <key>NSPortName</key><string>$(PRODUCT_NAME)</string>
  <key>NSSendFileTypes</key><array><string>public.movie</string></array>
</dict></array>
```
```swift
final class ServiceProvider: NSObject {
  @objc func downscaleFiles(_ pb: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    Task { @MainActor in AppModel.shared.quickRun(urls) }
  }
}
// applicationDidFinishLaunching: NSApp.servicesProvider = ServiceProvider(); NSUpdateDynamicServices()
```

## 2. Shortcuts (App Intents)

Recommendation: intents in the **main app target** (not an AppIntentsExtension) so they share the process, the JobQueue and the saved settings. DTS also advises main-app placement for anything that must open the app (https://developer.apple.com/forums/thread/770421).

```swift
struct DownscaleVideosIntent: AppIntent {
  static let title: LocalizedStringResource = "Downscale videos"
  static var supportedModes: IntentModes { .background }   // macOS 26; use `static let openAppWhenRun = false` pre-26
  @Parameter(title: "Videos", supportedContentTypes: [.movie]) var files: [IntentFile]
  @Parameter(title: "Quality") var preset: QualityPreset?        // AppEnum, optional -> falls back to saved default
  @Parameter(title: "Destination") var destination: DestinationOption?

  @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
    let urls = try files.compactMap { try $0.fileURL ?? stage($0) }   // IntentFile may be data-only; copy to temp
    let outputs = try await AppModel.shared.quickRun(urls, preset: preset, destination: destination)  // awaits queue completion
    return .result(value: outputs.map { IntentFile(fileURL: $0) })
  }
}
struct AppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] { AppShortcut(intent: DownscaleVideosIntent(), phrases: ["Downscale videos with \(.applicationName)"], shortTitle: "Downscale", systemImageName: "film") }
}
```
Key points:
- `IntentFile` carries `fileURL` (optional) and `data`; from Shortcuts/Finder it is normally a file URL, but treat it as possibly temporary: copy to a staging dir before enqueueing, and do not Replace/trash an original through a staged copy. Sandbox is off for this app (Direct DMG), so security-scoped access is not an issue. [exp]
- Intents run in the app process, creating it in the background if not running (no Dock bounce when `LSUIElement` or when mode is `.background`; a normal app may still show briefly). `perform()` must stay alive until the job finishes to return output files; long jobs risk Shortcuts timeouts. Offer a "Wait for completion" Bool param: false returns immediately with planned output paths (not ready), true awaits. [exp]
- Single queue: `AppModel.shared` (a `@MainActor` singleton) must exist before SwiftUI scenes; do not construct a second queue in the intent. Intents can run before any scene is created, so initialize the model in the `App` init or the app delegate, not in a view's `.task`.
- Return files: `.result(value: [IntentFile])` with `ReturnsValue<[IntentFile]>`; use `IntentFile(fileURL:, filename:, type:)`. Output dir must outlive the run (not a temp dir the queue deletes).
- Skipped files (loss policy): return only converted outputs, post the notification (section 5), and optionally throw nothing. A partial result is fine.
- Unsigned: no entitlement is required for App Intents. Metadata extraction runs at build time via Xcode (`appintentsmetadataprocessor`); SwiftPM-only builds may not generate it, so the app target must be built by Xcode/xcodebuild with the intent types in the app target, not inside a Swift package linked statically (known pitfall; put intents in the app target or use the `AppIntentsPackage` protocol in macOS 26). [exp] Verify with `Metadata.appintents` inside the built .app.
- Known forum friction: file parameter receiving user-selected files had issues (https://developer.apple.com/forums/thread/832575); "internal error" in Shortcuts for basic intents (https://developer.apple.com/forums/thread/770421). Budget spike time.
- WWDC25 "Get to know App Intents" / "Develop for Shortcuts and Spotlight with App Intents" cover the mode API: https://developer.apple.com/videos/play/wwdc2025/244/

## 3. Menu bar

Recommendation: use SwiftUI `MenuBarExtra { ... } label: { ... }.menuBarExtraStyle(.window)` for the panel and live progress; make the **status icon itself** a drop target through AppKit.

- Progress: the `label` closure is a live SwiftUI view; use `Label`/`Image(systemName:)` plus `Text(percent)`, or a rendered `NSImage`/`ImageRenderer` ring that updates with the observable queue. Text in the label works and updates. Keep it small (status items clip). [doc/exp] https://developer.apple.com/documentation/swiftui/menubarextra
- Drops inside the `.window` popup: `.dropDestination(for: URL.self) { urls, _ in ... }` or `.onDrop(of: [.fileURL])` works as on any view, but the user can only reach it after the window opens. Opening a window mid-drag does not work by hover for SwiftUI's MenuBarExtra. [exp]
- Drops on the status item: SwiftUI has no modifier for this; `MenuBarExtra` exposes neither the NSStatusItem nor its button. Options: (1) `MenuBarExtraAccess` package (https://github.com/orchetect/MenuBarExtraAccess) gives `NSStatusItem` via `.menuBarExtraAccess(isPresented:) { statusItem in ... }`, then register the button; (2) drop SwiftUI's MenuBarExtra and own an `NSStatusItem` + `NSPopover` hosting SwiftUI (what most drop-target menu bar apps do). [forum/exp]
```swift
// Option 1 sketch
final class DropButtonHost: NSObject { }  // button's superclass can't change; use a transparent overlay NSView instead:
final class DropView: NSView {
  var onDrop: (([URL]) -> Void)?
  override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
  required init?(coder: NSCoder) { fatalError() }
  override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
    let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    onDrop?(urls); return !urls.isEmpty
  }
}
// statusItem.button?.addSubview(DropView(frame: button.bounds)) with autoresizingMask [.width,.height]; make hitTest return nil for clicks if you still want the button to receive clicks.
```
- Verdict: for v1, recommended path is MenuBarExtraAccess (small dependency) or a hand-rolled NSStatusItem+NSPopover. Decide in a spike; if the overlay swallows clicks, forward `mouseDown` to `button.performClick`. Dropping on the overlay must filter UTIs (movie) and ignore others.
- Caveats: macOS 26 menu bar can hide/reorder third-party items, and there is the "Allow in the Menu Bar" toggle in System Settings > Menu Bar; the user may need to allow it. [exp] LSUIElement apps with no Dock icon cannot show the Dock drop, so keep the Dock icon on (spec requires Dock drop).

## 4. Dock icon drop (and "Open With")

Recommendation: AppKit delegate, not `onOpenURL`.
```xml
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Video</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array>
    <string>com.apple.quicktime-movie</string><string>public.mpeg-4</string><string>com.apple.m4v-video</string>
  </array>
</dict></array>
```
```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
  func application(_ app: NSApplication, open urls: [URL]) { Task { @MainActor in AppModel.shared.addFromDock(urls) } }
}
@main struct App: SwiftUI.App { @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate ... }
```
- `Alternate` keeps aarik from hijacking QuickTime/Photos as the default for .mov; the Dock icon still highlights for matching drops. Use `Viewer`. Avoid `public.data`: it makes the icon accept anything.
- `application(_:open:)` fires for Dock drops, Finder "Open With", and `open -a`, both at cold launch (before any scene exists, so buffer into the model) and while running. A SwiftUI `WindowGroup` may open a new window for each open event; handle with `.handlesExternalEvents(matching: [])` or use `Window` (single-instance) scenes. Do not also use `onOpenURL` for files: both fire (reported in https://developer.apple.com/forums/thread/769600).
- Forum caveat: first drop sometimes ignored when launched from Xcode; test the installed copy; LaunchServices registration is by path, so duplicates (DerivedData + /Applications) confuse routing. [forum]
- Unsigned: fine; document types are plain Info.plist/LaunchServices data. Gatekeeper does not affect it once the app is allowed to open.

## 5. Notifications with actions

- Works unsigned? `UNUserNotificationCenter` requires a real `.app` bundle with a bundle identifier and *a* code signature; ad-hoc ("Sign to Run Locally"/`codesign -s -`) is sufficient for authorization to be granted, and bare binaries fail with "Notifications are not allowed for this application". [forum] https://developer.apple.com/forums/thread/837941 , https://forum.xojo.com/t/macos-unusernotificationcentermbs-user-notifications-works-during-debug-but-dont-work-for-build-app/83588 . Unsigned code does not run on Apple silicon anyway (DTS). No push entitlement is needed for local notifications. Notification permission is keyed by bundle id + path, so re-signing/moving the app between builds can reset or duplicate the entry; ad-hoc signature changes each build (cdhash), which has made macOS re-prompt in some reports. [exp]
- Gap: I found no report of "authorized but banner never shown" specific to ad-hoc builds; test with Focus off and Notifications set to Banners in System Settings.
```swift
let center = UNUserNotificationCenter.current()
center.delegate = notificationDelegate   // set in applicationDidFinishLaunching, BEFORE any intent posts
let open = UNNotificationAction(identifier: "REVIEW_SKIPPED", title: "Review skipped files", options: [.foreground])
center.setNotificationCategories([UNNotificationCategory(identifier: "QUICKRUN_DONE", actions: [open], intentIdentifiers: [])])
try await center.requestAuthorization(options: [.alert, .sound])   // ask at first quick run / Settings toggle, not launch
let c = UNMutableNotificationContent(); c.title = "3 converted, 2 skipped"; c.categoryIdentifier = "QUICKRUN_DONE"
c.userInfo = ["skippedBookmarks": [...]]    // small; store skipped list in the JobStore keyed by run id and pass only the id
try await center.add(UNNotificationRequest(identifier: runID, content: c, trigger: nil))
// delegate: userNotificationCenter(_:didReceive:) -> read run id, bring app forward, load skipped files into the queue UI
```
- Clicking the banner (default action) launches/activates the app and calls `didReceive`; if the app was quit, the delegate must be installed at launch to receive it (the response is delivered after launch). Persist the skipped list on disk (already have JobStore) because userInfo is size-limited and the app may relaunch.
- Skip posting when the app is frontmost (spec §8.6); `willPresent` can return `[]`.

## Spike checklist before Plan 4 commits (ad-hoc build in /Applications, macOS 26)
1. Intent appears in Shortcuts.app; "Use as Quick Action" > Finder shows it on right-click of 1 and 3 .mov files; `perform()` runs with app not running; output files returned to a following "Show in Finder" action.
2. NSServices item shows under Finder right-click > Services with `public.movie` selection.
3. Status item overlay accepts a .mov drop; click still toggles the popover.
4. Dock drop at cold launch and while running delivers URLs once.
5. Notification authorization granted, action fires `didReceive` after app quit.

## Sources
- IntentModes: https://developer.apple.com/documentation/appintents/intentmodes.md ; supportedModes: https://developer.apple.com/documentation/appintents/appintent/supportedmodes.md
- openAppWhenRun superseded: https://developer.apple.com/forums/thread/804015 ; extension limits: https://developer.apple.com/forums/thread/770421
- Intents missing in macOS Shortcuts: https://developer.apple.com/forums/thread/743121 ; IntentFile issue: https://developer.apple.com/forums/thread/832575
- WWDC25 Shortcuts/Spotlight App Intents: https://developer.apple.com/videos/play/wwdc2025/244/ ; https://developer.apple.com/videos/play/wwdc2025/260/
- Finder Quick Action via Shortcuts (third-party): https://flaviocopes.com/courses/automate-macos/build-a-finder-quick-action/
- Finder Sync problems: https://developer.apple.com/forums/thread/756711 ; https://developer.apple.com/forums/thread/806607
- Dock drop in SwiftUI: https://developer.apple.com/forums/thread/769600
- MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra ; MenuBarExtraAccess: https://github.com/orchetect/MenuBarExtraAccess
- Notifications unsigned/ad-hoc: https://developer.apple.com/forums/thread/837941
