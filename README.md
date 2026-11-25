<p align="center"><img src="Branding/mark-200.png" alt="" height="200"></p>

# aarik

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
xattr -dr com.apple.quarantine /Applications/aarik.app
```

Because the signature changes with each release, macOS may ask you to grant Photos access again after an update.

## Build from source

You need Xcode 27 (or any Xcode with the macOS 26 SDK and Swift 6) on Apple silicon.

```sh
scripts/run-app.sh                          # build and launch the app
cd Packages/AppModules && swift test        # run the unit tests
scripts/make-dmg.sh                         # build a release DMG into build/dist
```

## Privacy

The app makes no network connections. Your videos, their metadata and your Photos library never leave your Mac.

## License

GPL-3.0. See [LICENSE](LICENSE).
