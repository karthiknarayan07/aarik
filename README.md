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

Videos can be sent to the app without opening its window. A quick run converts in the background with your saved
defaults (Settings: preset and Save to), never asks a question and never replaces an original: if Replace is the
saved choice, the copy is saved next to the original and the notification says so. Any video that would lose metadata,
and any the app would keep as is, is skipped. One notification says how many were converted, how much space was saved
and how many were skipped; "Review skipped files" opens them in Local Files.

**Dock drop and Open With** (right-click a video ▸ Open With, or drop videos on the app's Dock icon) follow one rule:

- If the app's window is open, the files are only added to Local Files. Nothing is queued.
- If no window is visible (it was closed, or the app wasn't running), the files go through a quick run.

Closing the window keeps the app running (it stays in the Dock, and in the menu bar when that item is on) so a quick
run can finish; ⌘Q quits. A Dock click brings the window back. With auto-start off in Settings, quick-run videos wait
until you resume the queue.

The app is listed under Open With as an alternate; it never becomes the default player. Quick runs use the same queue
as the window, so they never convert two videos at once.

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
