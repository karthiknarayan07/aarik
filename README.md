<p align="center"><img src="Branding/mark-200.png" alt="" height="200"></p>

# Aarik

A free, offline, open-source Mac toolbox for converting video, images, PDFs and documents without losing metadata.

The first tool shrinks iPhone 4K video to 1080p while keeping what makes the footage yours: Dolby Vision HDR, location, and camera metadata such as capture date, make and model. Smaller files mean you can reclaim a lot of space in Photos and iCloud, because the large originals can be replaced with the compact versions.

## Status

In development. There is no stable release yet, and the interface and behavior will change.

## Requirements

- macOS 26 or later
- A Mac with Apple silicon (M1 or newer). Intel Macs are not supported.

## Install

1. Download the latest `.dmg` from the Releases page of this repository.
2. Open the disk image and drag the app into the Applications folder.
3. Open the app from Applications.

The app is not yet signed with an Apple Developer ID or notarized, so macOS blocks it on first launch. To allow it:

1. Try to open the app once. When macOS says it cannot verify the app, dismiss the dialog.
2. Open System Settings, then Privacy & Security.
3. Scroll to the Security section, find the message about the app being blocked, and click Open Anyway.
4. Confirm with your password or Touch ID, then open the app again.

Alternatively, remove the quarantine flag from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Aarik.app
```

Because the signature changes with each release, macOS may ask you to grant Photos access again after an update.

## Quick runs

A quick run shrinks videos in the background, without opening the window. It uses your saved defaults (Settings: Default
Preset and Save converted videos) and never asks a question. There are several ways to start one.

**Dock drop and Open With.** Drop videos on the app's Dock icon, or right-click a video and choose Open With. One rule
decides what happens:

- If the app's window is open, the videos are only added to Local Files. Nothing is converted.
- If no window is visible (you closed it, or the app wasn't running), the videos are converted as a quick run.

Closing the window keeps the app running in the Dock so a quick run can finish; ⌘Q quits. A click on the Dock icon brings
the window back. The app is listed in Open With as an alternate and never becomes the default player.

**The menu bar item.** The app puts an icon in the menu bar (turn it off in Settings ▸ General ▸ Show in Menu Bar). It
shows progress while videos convert. Drop videos on the icon, or click it and drop them on the popover, or click
Choose Videos… in the popover. The popover shows the current job, Pause Queue and Open Main Window, and
when a run ends it says how many videos were shrunk or skipped, with Show Skipped… to look at the skipped ones, and how
many dropped items weren't videos. When
you open the popover with the mouse, macOS keeps the app in the background, so the popover can't take the Esc or Tab
keys; open it with VoiceOver or from the keyboard (or click its buttons) if you need them.

**The Shrink Videos action in Shortcuts.** Open Shortcuts, search for Shrink Videos and add it to a shortcut. Give it
videos, or let it pick them by date range, resolution and source (Local Files or Photos), and choose the quality, format
and destination. It can wait and hand the finished videos to the next action.

To put it in Finder's right-click menu: in Shortcuts, make a shortcut that starts with the Shrink Videos action, open its
details and turn on Use as Quick Action, then choose Finder. After that, right-click videos in Finder and look under
Quick Actions. Settings ▸ General ▸ Finder has the same steps and a button that opens Shortcuts.

**Siri and Spotlight.** Say "Shrink videos with Aarik" or type it in Spotlight. Spotlight also lists the action and its
ready-made variants, such as shrinking last month's videos or your 4K videos.

**Services.** Select videos in Finder, then use the right-click menu ▸ Services ▸ Shrink Videos. macOS keeps new
Services turned off, so it does nothing until you turn it on: System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services ▸
Files and Folders ▸ Shrink Videos. Settings ▸ General ▸ Services has a button that opens the Keyboard pane. The Finder
Quick Action above is the more dependable way to get this into Finder.

**What a quick run never does.**

- It never replaces an original. If Replace is your saved choice, the copy is saved next to the original instead and the
  notification says so. Replacing always needs a confirmation in the window.
- It skips any video that would lose metadata, and any video the app would keep as is (already small, or less than
  10 % smaller). Skipped videos are counted and listed: "Review skipped files" in the notification, or Show Skipped… in
  the menu bar popover, opens them in Local Files.
- It never converts two videos at once: quick runs share the queue with the window. With Start the queue automatically
  off in Settings, quick-run videos wait until you press Resume.
- It posts one notification per run when it ends. Runs from the Dock, Open With, Services and Shortcuts post none while
  the app's window is in front; runs from the menu bar post none while the menu bar panel is open. If you don't get
  any, allow notifications for the app in System Settings ▸ Notifications (Settings ▸ General ▸ Notifications has a button).

**Because the app is unsigned.** Until a signed release exists, macOS can be stricter with these entry points. Shortcuts,
Spotlight and Siri may need the app to be in the Applications folder and opened once before they list the action, and
may take a while to show it. A new Service may need `pbs -flush` in Terminal before it appears. macOS may refuse
notifications for an unsigned build, in which case a quick run still works and finishes silently. Each update changes
the app's signature, so macOS may ask you to allow things again.

## Updates

The app checks for new versions in the background and offers to install them (App menu ▸ Check for Updates…). Updates
are verified with an EdDSA signature before they are installed. Turn automatic checks off in Settings ▸ General.
Builds you make yourself in Debug never check for updates.

## Build from source

You need Xcode 27 (or any Xcode with the macOS 26 SDK and Swift 6) on Apple silicon.

```sh
scripts/run-app.sh                          # build and launch the app
cd Packages/AppModules && swift test        # run the unit tests
scripts/make-dmg.sh                         # build a release DMG into build/dist
```

## Privacy

Your videos, their metadata and your Photos library never leave your Mac. The only network connection the app makes is
the update check, which downloads the update feed from this project's GitHub Pages site and sends nothing about you or
your files beyond what any web request carries (Sparkle's optional system profile is off). Turn it off in Settings ▸
General.

## Releasing

See [docs/RELEASING.md](docs/RELEASING.md) and [CHANGELOG.md](CHANGELOG.md).

## License

GPL-3.0. See [LICENSE](LICENSE).
