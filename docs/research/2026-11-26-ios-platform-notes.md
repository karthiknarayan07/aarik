# iOS platform notes for Plan 10 (Tasks 4-11)

Date: 2026-11-26. Branch `plan-10/research`.

## How to read this

- **[SDK]** means checked against the local SDK: `iPhoneOS27.2.sdk` (Xcode 27.2), under
  `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk/System/Library/Frameworks`.
  Headers and `.swiftinterface` files (arm64e-apple-ios) were grepped.
- **[WWDC]** means read on the cited session page this session.
- **[Unverified]** means from prior knowledge. Apple's doc pages are JavaScript-rendered and came back title-only
  through the fetch tool, so I could not read them. Check these on a device or against the live page before relying on them.
- The installed SDK is iOS 27.2 but our floor is iOS 26. Gate anything marked 27 behind `#available`.
- Installed Simulator runtimes: **iOS 26.5 (23F77)** and **iOS 27.0 (24A434)**.

---

## 1. BGContinuedProcessingTask (iOS 26+, iPhone and iPad only)

Sources: `BackgroundTasks.framework/Headers/BGTask.h`, `BGTaskRequest.h`, `BGTaskScheduler.h` [SDK];
WWDC25 session 227, https://developer.apple.com/videos/play/wwdc2025/227/ [WWDC];
https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados [Unverified].

**API shapes [SDK]**

```swift
BGContinuedProcessingTaskRequest(identifier: String, title: String, subtitle: String)
request.strategy = .fail          // or .queue (the default)
request.requiredResources = []    // or .gpu
BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
    let task = task as! BGContinuedProcessingTask   // BGTask + NSProgressReporting
    task.expirationHandler = { /* flag the work to stop */ }
    task.progress.totalUnitCount = N; task.progress.completedUnitCount += 1
    task.updateTitle("...", subtitle: "...")        // changes the title and subtitle the system shows
    task.setTaskCompleted(success: true)
}
try BGTaskScheduler.shared.submit(request)          // throws BGTaskScheduler.Error
BGTaskScheduler.supportedResources                  // class property: which Resources this device supports
```

**Identifiers and Info.plist**

- `BGTaskSchedulerPermittedIdentifiers` must contain the identifier.
- The identifier must start with the app's bundle ID. A wildcard form ends in `.*`, for example
  `com.foo.App.convert.*`. At submit and register time you append a dynamic suffix, for example
  `com.foo.App.convert.<jobID>` [SDK header, WWDC].
- The header says `earliestBeginDate` is ignored (treated as now) for continued tasks.
- Create the request on behalf of the foreground app. The header says apps and extensions should use this initializer
  because of the tie to the foreground app.

**Registration is different from other BG tasks.** Normal launch handlers must be registered before launch finishes.
`BGContinuedProcessingTask` registrations are exempt [SDK, BGTaskScheduler.h]. WWDC shows registering at the moment the
user's intent is expressed, then submitting. Register each concrete identifier only once: the system kills the app on a
second registration of the same identifier, so use a unique suffix per run and make registration idempotent per job ID.

**Submission strategy**

- `.queue` (the default): if the system cannot run it now, it goes at the back of a queue. **Queued requests are
  cancelled when the user removes the app from the app switcher** [SDK].
- `.fail`: throws `BGTaskSchedulerErrorCodeImmediateRunIneligible` (4) when it cannot run right away. This
  gives instant feedback [SDK, WWDC].
- `NotPermitted` (3) is thrown when the identifier is not in Info.plist, when a requested resource (GPU) is unavailable,
  or when the user has denied background launches [SDK].
- Recommendation: use `.fail` for a user tap on "Start", so we can say "can't run in the background right now" and keep
  running in the foreground. Use `.queue` only if we accept losing the request on swipe-away.

**Progress and expiration**

- Progress is mandatory. Tasks that report none are expired. If progress is slow, the system asks the user whether to
  continue. "Tasks that appear stalled may be forcibly expired" [SDK header, WWDC].
- Update `task.progress` often and monotonically. A Progress with `totalUnitCount` equal to bytes or frames is fine.
- The expiration handler must flip a flag quickly, then `setTaskCompleted(success: false)` after the clean stop. For
  Aarik that is: cancel the encoder, remove the partial output, set the job back to `.queued`.
- Expiration is driven by system conditions and by the user pressing Stop in the system UI. Treat both the same way.

**GPU**

- `.gpu` needs the entitlement `com.apple.developer.background-tasks.continued-processing.gpu` (Xcode capability
  "Background GPU access") [SDK]. Submissions are rejected without it, and not every device supports it, so check
  `BGTaskScheduler.supportedResources` first.
- VideoToolbox hardware encode is a media-engine job, not GPU compute. Start with `requiredResources = []`. Request
  `.gpu` only if profiling shows our pipeline (Metal tone-mapping or scaling) needs it. That also avoids needing the
  entitlement on free-Apple-ID device builds [Unverified: signing rules for this entitlement].

**What the user sees [WWDC]**

- A system progress UI with our title and subtitle, a progress bar, and a cancel control. The header calls it
  "the live activity" (`updateTitle:subtitle:`).
- On completion the UI updates briefly, then dismisses itself.
- Apple's stated fit: starts from an explicit user action, has a clear goal, has measurable progress. Not for
  background maintenance or sync. Aarik's "Start" fits.
- While backgrounded the task may get lower QoS. When the app returns to the foreground it is boosted [WWDC].

**Simulator support**: not covered in the WWDC session. [Unverified] Treat it as "may run, not representative". Plan on
a real-device checklist for background continuation (already in the spec) and on a fake scheduler seam for tests.

**Plan impact**: the plan registers handlers with identifiers in `BGTaskSchedulerPermittedIdentifiers`. That is right,
but registration happens per run at submit time, not in `didFinishLaunching`. The scheduler seam needs `register`,
`submit(strategy:)`, `updateTitle`, `progress` and a way to fire expiration.

---

## 2. ActivityKit Live Activities

Sources: `ActivityKit.framework` swiftinterface [SDK]; https://developer.apple.com/documentation/activitykit [Unverified].

**API shapes [SDK]**

```swift
let content = ActivityContent(state: S, staleDate: Date?, relevanceScore: Double = 0)
let a = try Activity<Attrs>.request(attributes:, content:, pushType: nil)   // pushType nil = local only
await a.update(content)                      // also update(_:alertConfiguration:timestamp:)
await a.end(finalContent, dismissalPolicy: .immediate | .default | .after(date))
ActivityAuthorizationInfo().areActivitiesEnabled
ActivityAuthorizationInfo().frequentPushesEnabled
```

iOS 26 adds `request(attributes:content:pushType:style:alertConfiguration:start:)` and an `ActivityStyle` [SDK]. We do
not need either.

**Facts to apply [Unverified, from Apple docs memory]**

- Info.plist: `NSSupportsLiveActivities = YES` in the app target. `NSSupportsLiveActivitiesFrequentUpdates` is for
  push-driven apps. We do local updates, so skip it.
- Local updates are not APNs-metered, but the system can still throttle or drop updates it judges too frequent. Apple
  publishes no number. "At most once a second" is conservative. Better: update on a change in whole percent or item
  index, coalesce to about 1 Hz, and skip updates when nothing changed.
- Limits: an active activity runs at most 8 hours. After `end` it may stay on the Lock Screen up to 4 more hours.
  ContentState is limited to 4 KB, so send ids, counts, a progress fraction and short strings.
- Dynamic Island: expanded (leading, trailing, center, bottom), compact leading and trailing, and minimal. Use
  `ProgressView(value:)` and a queue count, not a timer.
- Ending: `.immediate` on cancel and pause. A short `.after(now + 5 min)` on finish, with a final "Done: saved X GB".
- `request` throws if the user disabled Live Activities. Check `areActivitiesEnabled` first.

**Interplay with the continued-processing system UI**

- `BGContinuedProcessingTask` already shows its own Live Activity-style UI with title, subtitle and progress, and
  `updateTitle:subtitle:` edits it [SDK]. So there are two candidate surfaces for the same run.
- [Unverified, needs a device test] Running our own `Activity` in parallel may show two items for one run. Decision for
  Task 7: first try the system UI alone, with `updateTitle` carrying "Item 3 of 12" and the filename. Add our own Live
  Activity only for the richer Dynamic Island and queue-count layout, after a device check that the two do not
  duplicate. This could shrink Task 7.

---

## 3. Share extension

Sources: `Foundation.framework/Headers/NSItemProvider.h`, `NSExtensionContext.h` [SDK]; the rest [Unverified].

- **Memory**: share extensions have a hard memory cap well below the app's (commonly cited as about 120 MB; it varies
  by device and OS). Exceeding it terminates the extension with no error. Never load a movie into `Data`.
- **Large movies**: use `loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in ... }`
  [SDK, NSItemProvider.h line 203]. The URL is a temporary file that is **deleted when the completion handler
  returns**, so copy it inside the handler with `FileManager.copyItem` (a file-system copy, no memory use) into the App
  Group `Staging/<uuid>/`. Do not hop queues before copying. `loadInPlaceFileRepresentation` (line 213) gives a URL to
  the original but only for providers that support it, with security-scoped access. Prefer `loadFileRepresentation`.
- The returned `Progress` can drive a progress bar. Items from Photos may be iCloud-optimised, so the provider can
  download first. Show progress and honour cancel.
- Activation rule: `NSExtensionActivationSupportsMovieWithMaxCount`, not `TRUEPREDICATE`.
- **Opening the containing app**: the SDK only offers `NSExtensionContext.open(_:completionHandler:)`, documented as
  "Asks the host to open a URL on the extension's behalf" [SDK]. In practice only some extension types honour it
  (Today and widgets, iMessage, a few others), and **not share extensions** [Unverified, long-standing behaviour]. The
  old `UIApplication` responder-chain workaround is blocked on recent iOS. Plan for it not to work. The plan's native
  confirmation with "Open Aarik" must degrade gracefully:
  (a) the confirmation says "Added to Aarik. Open Aarik to start." with no button, and the app picks staged items up
  on activation (already in the plan);
  (b) the extension posts a local notification (needs permission) whose tap opens the app.
  Test `open` on iOS 26 on a device. Do not build the UX around it.
- App Group container: `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. Needs the App Group
  capability on both targets. Simulator builds work without a team.
- Staging copies must not follow symlinks and must skip non-videos (already in the plan).

---

## 4. WidgetKit ControlWidget, timelines, App Group

Sources: `WidgetKit.swiftinterface` and `AppIntents.swiftinterface` [SDK]; WWDC24 "Extend your app's controls across
the system" (10157) [Unverified].

**API shapes [SDK, iOS 18+]**

```swift
struct PauseControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "...", provider: PauseProvider()) { isPaused in
      ControlWidgetToggle(isOn: isPaused, action: SetPausedIntent()) {
        Label("Convert", systemImage: "...")
      } valueLabel: { on in Text(on ? "Paused" : "Running") }
    }
  }
}
// StaticControlConfiguration(kind:provider:content:), Provider: ControlValueProvider
// ControlWidgetToggle(isOn:action:label:valueLabel:), Action: SetValueIntent, Action.ValueType == Bool
struct SetPausedIntent: SetValueIntent { @Parameter(title: "Paused") var value: Bool; func perform() async throws -> some IntentResult }
ControlCenter.shared.reloadControls(ofKind:) / reloadAllControls()
WidgetCenter.shared.reloadTimelines(ofKind:) / reloadAllTimelines()
```

- `ControlValueProvider.currentValue()` reads shared state from the App Group; it also needs a `previewValue`.
- The intent's `perform()` runs in the widget extension process unless the intent is also compiled into the app. Keep it
  tiny: write the flag to the App Group (`UserDefaults(suiteName:)` or a small JSON file), then call
  `ControlCenter.shared.reloadControls`. The app observes the change.
- Cross-process observation: a Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`) is the instant path;
  `UserDefaults` KVO on the suite works but is slower. Pair either with a re-read on `scenePhase == .active`.
- **Reloading from the app**: call `WidgetCenter.shared.reloadTimelines(ofKind:)` when the snapshot changes. The reload
  budget is system-managed, so "no polling" is right. Reload on state changes only (job finished, queue count
  changed), not per progress tick.
- Home Screen widget: `StaticConfiguration` with a `TimelineProvider` returning one entry that reads the snapshot. Use
  `.containerBackground(for: .widget)`.
- A control can open the app: use an `AppIntent` with `supportedModes = .foreground` (see section 5).
- Controls, widgets, share extension and app all need the same App Group entitlement and suite name (set in xcconfig).

---

## 5. App Intents foreground mode on iOS 26

Sources: `AppIntents.swiftinterface` [SDK]; WWDC25 session 244, https://developer.apple.com/videos/play/wwdc2025/244/ (partial) [WWDC].

**API shapes [SDK]**

```swift
static var supportedModes: IntentModes { get }          // anyAppleOS 26
IntentModes.background
IntentModes.foreground                                  // opens the app before perform()
IntentModes.foreground(.immediate | .deferred | .dynamic)
func continueInForeground(_ dialog: IntentDialog? = nil, alwaysConfirm: Bool = true) async throws
func needsToContinueInForegroundError(_:alwaysConfirm:) -> AppIntentError
IntentSystemContext.currentMode   // .background / .foreground; has .canContinueInForeground
```

- `static var openAppWhenRun: Bool` is **deprecated in 26.0**: "Please provide 'supportedModes' instead" [SDK].
  `ForegroundContinuableIntent` and `requestToContinueInForeground` are deprecated too, in favour of
  `.foreground(.dynamic)` [SDK].
- WWDC25: by default an intent does not foreground the app. `supportedModes = .foreground` opens the app before
  `perform()` [WWDC]. `OpenIntent`s open the app automatically.
- For us: `ShrinkVideosIntent` uses `static let supportedModes: IntentModes = .foreground`, `@MainActor perform()`,
  stages inputs through `StagedInputs`, then hands off to the app model. Because the app is frontmost, the
  `BGContinuedProcessingTaskRequest` ("must start from an explicit user action") is legitimate.
- `.foreground(.dynamic)` lets the intent run in the background and ask to continue in the foreground when needed. Not
  needed for v0.1.0.
- `supportedModes` is `anyAppleOS 26`, so macOS 26 compiles it too; no `#available` is needed with a 26 floor.

**File parameters [SDK]**: `IntentFile` has `fileURL: URL?`. Use
`@Parameter(title:, supportedContentTypes: [.movie]) var files: [IntentFile]`; `supportedContentTypes:` is accepted by
every `IntentParameter` initializer. Copy to the Staging folder first thing in `perform()`, because the URL may be a
temporary file. Avoid reading `IntentFile.data` for large movies.

---

## 6. PhotoKit on iOS

Sources: `Photos.framework/Headers`, `PhotosUI.framework/Headers/PHPhotoLibrary+PhotosUISupport.h` [SDK].

- **Access levels**: `PHPhotoLibrary.requestAuthorization(for: .readWrite)` returns `.authorized`, `.limited`,
  `.denied`, `.restricted` or `.notDetermined`. `.addOnly` is enough for saving only [SDK, PHPhotoLibrary.h].
- **Limited library**: fetches return only the selected assets, plus assets the app itself saves. Show a native banner
  and a button calling `PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)` or the variant
  `presentLimitedLibraryPicker(from:completionHandler:)` (iOS 15+), which passes back newly added identifiers [SDK].
  It does nothing unless the user is in limited mode. Set `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES` in
  Info.plist if we present the picker ourselves, otherwise the system prompts on its own [SDK, header comment].
  SwiftUI has no direct API, so wrap the call using the key window's root view controller. Register a
  `PHPhotoLibraryChangeObserver` so the grid refreshes after the picker.
- **Fields without downloading originals** [SDK, PHAsset.h]: `pixelWidth`, `pixelHeight`, `duration`, `creationDate`,
  `location`, `mediaType`, `mediaSubtypes`, `isFavorite`, `hasAdjustments`, `burstIdentifier`, `sourceType`. There is
  **no frame-rate or codec property**, so iOS fps is `nil` until the file is local (Task 4, `iosFpsUnknownUntilLocal`).
  To probe local availability, request a `PHAssetResource` with `isNetworkAccessAllowed = false` [SDK,
  PHAssetResourceManager.h]; that it fails instead of downloading is [Unverified].
- To read track metadata (fps, codec) we need the file. Download once through
  `PHAssetResourceManager.requestData(for:options:)` or `writeData(for:toFile:options:)` with network access allowed,
  writing to disk (never in memory). This is the existing one-at-a-time iCloud download path.
- **Saving**: `PHAssetCreationRequest.forAsset()` then `addResource(with: .video, fileURL:, options:)` with
  `options.shouldMoveFile = true` to avoid a second copy [SDK, PHAssetCreationRequest.h]. The simpler
  `PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:)` exists too [SDK]. Metadata inside the movie is
  kept because the file is stored as-is. Creation date, location and favourite live in the Photos database, so set
  `creationDate`, `location` and `isFavorite` on the request explicitly to match the original (ADR 0002 on the Mac), and
  verify on a Simulator library.
- **Deleting**: `PHAssetChangeRequest.deleteAssets(_:)` inside `performChanges`. iOS shows one system confirmation for
  the batch and the items go to Recently Deleted. We cannot suppress the prompt, which is what the plan wants. Needs
  `.readWrite`. In limited mode only assets in the selection can be deleted. [Unverified: prompt behaviour and 30-day
  retention are standard iOS behaviour, not read from the SDK.]

---

## 7. Thermal, Low Power Mode, battery, activities

Sources: `Foundation.framework/Headers/NSProcessInfo.h`, `UIKit.framework/Headers/UIDevice.h` [SDK].

```swift
ProcessInfo.processInfo.thermalState                  // .nominal/.fair/.serious/.critical
ProcessInfo.thermalStateDidChangeNotification         // read thermalState once before registering [SDK line 503]
ProcessInfo.processInfo.isLowPowerModeEnabled
Notification.Name.NSProcessInfoPowerStateDidChange    // Low Power Mode change [SDK line 494]
UIDevice.current.isBatteryMonitoringEnabled = true    // default false; batteryState is .unknown until true
UIDevice.current.batteryState                         // .unknown/.unplugged/.charging/.full
UIDevice.current.batteryLevel                         // 0...1, -1 if unknown
UIDevice.batteryStateDidChangeNotification / batteryLevelDidChangeNotification
let token = ProcessInfo.processInfo.beginActivity(options:, reason:)   // iOS 7+; endActivity(token)
```

- `UIDevice` is `@MainActor` in Swift 6, so wrap it in the `PowerSource` seam and hop to the actor that owns policy.
- `beginActivity` on iOS only affects throttling while the app is running. It does **not** keep a suspended app alive and
  does not replace `BGContinuedProcessingTask`. Keep it as a harmless carry-over; do not count on it for background time.
- Low Power Mode on iOS also curtails background activity. The 1-slot rule is right. Show "Low Power Mode: running one at a time".
- Map `.serious` and `.critical` to the existing Mac rules. Add pause at `.critical`.
- The Simulator reports `.nominal` and fixed battery values. `simctl status_bar override --batteryState/--batteryLevel`
  is cosmetic and does not change `UIDevice`. Fake the sources in unit tests.

---

## 8. Foundation Models on iOS and in the Simulator

Source: `FoundationModels.swiftinterface` [SDK].

```swift
let model = SystemLanguageModel.default          // iOS 26+
model.availability                               // .available / .unavailable(reason)
model.isAvailable
// UnavailableReason: .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady   [SDK]
LanguageModelSession(model: .default, tools: [], instructions: "...")
```

- `PrivateCloudComputeLanguageModel` (with `quotaUsage`; reasons `.deviceNotEligible` and `.systemNotReady`) is
  **iOS 27 only** [SDK]. Do not build on it with an iOS 26 floor.
- Whether the iOS Simulator uses the host Mac's on-device model could not be confirmed from the SDK or the fetched
  docs. [Unverified] My recollection is that it does, which needs an Apple Silicon Mac with Apple Intelligence enabled
  and the model downloaded. **Test it**: run the availability check in an iPhone 17 Pro Simulator and log the reason.
  Treat "unavailable" as a normal state; the plan already hides the features then.
- Re-check availability on `scenePhase == .active`, because the model can become ready after a download.

---

## 9. Simulator testing

All commands in this section were run on this machine.

**Devices and runtimes**

- Runtimes: `iOS 26.5 (23F77)` = `com.apple.CoreSimulator.SimRuntime.iOS-26-5`; `iOS 27.0 (24A434)` = `...iOS-27-0`.
- `simctl list devicetypes` lists **`iPhone Duo`** (`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, model
  `iPhone19,4`). Its profile has **`minRuntimeVersionString` 27.1.0**. `xcrun simctl create tmp-duo
  com.apple.CoreSimulator.SimDeviceType.iPhone-Duo` fails with "Could not find an available runtime for device type
  'iPhone Duo'". **No Duo Simulator can be created here until an iOS 27.1+ runtime is installed.** Installed are 26.5
  and 27.0, and neither lists the Duo as a supported device type.
- Existing devices (all Shutdown). iOS 26.5: iPhone 17 Pro, iPhone 17 Pro Max, iPhone 17e, iPhone Air, iPad Pro 11-inch
  (M5), iPad mini (A17 Pro), iPad Air 13-inch (M4), iPad Air 11-inch (M4), iPad (A16). iOS 27.0: iPhone 17e, iPhone Air
  and the same iPads.
- **There is no device named "iPhone 17"** and no "iPad Pro 13-inch" among the available devices. The plan's CI
  destination `platform=iOS Simulator,name=iPhone 17` fails today, and Task 11's "iPad Pro (13-inch)" does not exist.
  The iPhone 17 device type is listed, so `simctl create` can make it; otherwise use "iPhone 17 Pro" and the 11-inch iPad Pro.

**Commands**

```sh
xcrun simctl addmedia <device> <file>...     # photos, live photos, videos, vCards into Photos
xcrun simctl status_bar <device> override --time 9:41 --batteryState charged --batteryLevel 100 \
      --wifiBars 3 --cellularBars 4 --dataNetwork wifi        # also: list, clear
xcrun simctl ui <device> appearance dark|light
xcrun simctl ui <device> content_size accessibility-medium    # AX1; accessibility-large = AX2,
                                                              # accessibility-extra-large = AX3
xcrun simctl ui <device> increase_contrast enabled
xcrun simctl privacy <device> grant|revoke|reset photos <bundle-id>
```

- **Posture** (Duo only): `simctl help` has no posture subcommand. Hinge control comes from the Simulator tooling (the
  Claude iOS Simulator control tool offers `set_posture`: `closed`, `half_open` with angle 1-179, `open`). XCUITest
  cannot set posture, so drive it from the harness script. I did not find an XCUITest posture API in the SDK, but that
  grep was not exhaustive.
- `addmedia` puts media in the Simulator's own library, not the owner's. Limited and denied states are set with
  `simctl privacy` or the system prompt.
- XCUITest launch arguments: `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL` (AX3; AX1 is
  `...AccessibilityM`, AX2 `...AccessibilityL`) and `-AppleInterfaceStyle Dark` in `app.launchArguments`
  [Unverified, from memory]. The `simctl ui ... content_size` route above is verified against the help text and is more
  reliable for the matrix; keep launch arguments for single tests.
- Fixtures: `addmedia` a short HEVC clip (ideally 4K HLG) before each run.

---

## 10. VideoToolbox HEVC on iOS devices vs Simulator

Sources: `VideoToolbox.framework/Headers/VTCompressionProperties.h` [SDK]; the rest [Unverified].

- Available on iOS [SDK]: `kVTCompressionPropertyKey_AverageBitRate` (iOS 8+, soft target, CFNumber SInt32),
  `...DataRateLimits` (hard cap per window; set AverageBitRate too), `...ConstantBitRate`, `...VariableBitRate`,
  `...Quality`, and `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder` / `...Require...` (iOS 17.4+).
  The ADR 0001 properties (`HDRMetadataInsertionMode`, mastering display, content light level) should be compile-checked on iOS.
- Recent iPhones have a hardware HEVC encoder. On devices, require hardware
  (`RequireHardwareAcceleratedVideoEncoder`). Software HEVC encode on a phone is far too slow and hot.
- **Simulator**: it runs on the Mac, and VideoToolbox there generally reaches the host's encoder, but behaviour is not the
  device's. [Unverified] Treat throughput, thermal and memory numbers from the Simulator as non-representative.
  Correctness tests (bitrate in band, metadata kept, DV preserved) are valid. The real-device checklist covers performance.
- `AVAssetWriter` and `VTCompressionSession` both exist on iOS. We already use `VTCompressionSession` for DV (ADR 0001).
- **Memory for 4K on iPhone**: a 4K 10-bit 4:2:0 frame is about 25 MB when stored as 16-bit samples
  (3840 x 2160 x 1.5 x 2 bytes, about 24.9 MB); the usual P010 layout is that size. Keep the in-flight window small (3 to 5
  frames), reuse the pixel buffer pool, and run one 4K job at a time on iOS. Target peak resident memory under about
  500 MB [target, to be measured; jetsam limits are device-dependent and not published].

---

## Findings that most affect the plan

1. No iPhone Duo Simulator can be created here: the device type needs runtime 27.1+ and only 26.5 and 27.0 are installed.
2. There is no "iPhone 17" or "iPad Pro 13-inch" Simulator device, so the plan's CI destination and Task 11 matrix fail as written.
3. Continued-processing tasks register per run at submit time (wildcard id, unique suffix), not at launch, and their system UI may make our own Live Activity redundant.
4. Share extensions cannot reliably open the host app, so "Open Aarik" must degrade to a notification or an instruction.
5. `openAppWhenRun` is deprecated in 26; use `supportedModes = .foreground`.
