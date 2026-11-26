# Releasing

Releases are built by `.github/workflows/release.yml` when a tag `vX.Y.Z` is pushed. The workflow:

1. Fails before building if the tag doesn't match `MARKETING_VERSION` in `Config/macOS.xcconfig`, if the secret
   `SPARKLE_ED_PRIVATE_KEY` is missing, or if `APP_UPDATE_PUBLIC_KEY` is empty.
2. Builds the DMG with `scripts/make-dmg.sh` (ad-hoc signed), using the workflow run number as the build number
   (`CFBundleVersion`), so every release counts up.
3. Downloads Sparkle's tools for the same version the app links (checksum-verified), signs the DMG with EdDSA and
   adds an item to `appcast.xml` with the version, size, signature, release notes and minimum macOS.
4. Uploads the DMG to the GitHub Release, then publishes `appcast.xml` on the `gh-pages` branch.

The app reads its update feed from `https://<APP_GITHUB_OWNER>.github.io/<APP_GITHUB_REPO>/appcast.xml` (values in
`Config/Brand.xcconfig`). Debug builds have no feed and never check for updates.

## One-time setup (owner)

Do these once, on your own Mac. The private key never goes into the repository, a chat, an issue or a log.

1. **Get Sparkle's tools.** Download `Sparkle-<version>.tar.xz` for the version pinned in the project (see
   `SPARKLE_VERSION` in `release.yml`) from <https://github.com/sparkle-project/Sparkle/releases> and unpack it.

2. **Generate the signing keys.**

   ```sh
   ./bin/generate_keys
   ```

   This stores the private key in your login keychain and prints the public key. Keep the keychain item: it is your
   backup. If the private key is lost, installed copies can no longer be updated and users must download the app
   again by hand.

3. **Store the private key as a GitHub secret.** Export it to a file, add it as the repository secret
   `SPARKLE_ED_PRIVATE_KEY` (Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret), then delete the file:

   ```sh
   ./bin/generate_keys -x sparkle-private-key.txt
   gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-private-key.txt
   rm -P sparkle-private-key.txt
   ```

4. **Put the public key in the build.** In `Config/macOS.xcconfig` set

   ```
   APP_UPDATE_PUBLIC_KEY = <the public key printed by generate_keys>
   ```

   and commit it. The public key is not a secret. Running `./bin/generate_keys -p` prints it again.

5. **Check the feed address.** `APP_GITHUB_OWNER` and `APP_GITHUB_REPO` in `Config/Brand.xcconfig` must name the
   repository the workflow runs in; `APP_UPDATE_FEED_URL` in `Config/macOS.xcconfig` is built from them.

6. **Enable GitHub Pages.** After the first release has created the `gh-pages` branch: Settings ▸ Pages ▸ Build and
   deployment ▸ Deploy from a branch ▸ `gh-pages` / `(root)`. Check that
   `https://<owner>.github.io/<repo>/appcast.xml` opens.

## Before each release: performance checks (on the release Mac)

CI only reports performance numbers (the `performance-report` job uploads them); it enforces nothing. The 20 % rule is
checked here, on the Mac the baselines were recorded on, with nothing else running:

1. Engine benchmark, Release build, against the stored baseline (fails on more than 20 % worse time or memory):

   ```sh
   cd Packages/Core
   RUN_PERF_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter PerformanceTests
   ```

   After a deliberate change that moves the numbers, record the new baseline the same way with
   `RECORD_PERF_BASELINE=1` added, and commit `Tests/PerformanceTests/Baselines/baselines.json`.
2. Launch time: run `LaunchPerformanceTests` (UI tests, Release; see the file's header) and compare with the baseline
   (set "Max % Regression" to 20).
3. By hand, Release build: cold launch under 1 s, idle CPU under 1 %, idle memory under 150 MB, no hang over 250 ms
   in the Hangs instrument during a 20-video batch, and a 50-video batch with memory flat (under 10 % growth after
   warm-up) and every original intact on each failure.
4. ASan and TSan CI jobs are green.
5. E2, a real variable-frame-rate clip: the test fixtures for variable frame rate have no audio (a writer stall with
   audio was seen and its cause never found; the engine's stall deadline now fails such a job as "The encoder stopped
   responding" instead of hanging). So check the real case by hand: take one iPhone clip that has variable frame
   rate, audio and metadata (a screen recording or a slow-motion clip), convert it with the Release build, and confirm
   it finishes, the audio and metadata are kept (the report shows nothing lost) and the sound stays in sync. Use a
   test clip you made for this and keep it out of the repository; never commit personal media.

## Before each release: the iOS app (owner, on a real iPhone)

Scrolling and large-library checks, with `scripts/device-perf.sh`, are in `docs/testing/performance-and-device.md`.

CI covers what a Simulator can show: the iOS build, the package tests on a Simulator, the unit tests and the UI tests on
one iPhone (`scripts/ios-ui-tests.sh`). The Simulator has no hardware encoder, no thermal or battery state, no Live
Activity on a lock screen, no widget gallery, no Control Center and no real Photos library, so everything below is run by
hand, on a physical iPhone with a Release or TestFlight-style build, before tagging. Use **test assets only**: record or
import a few short clips for this; never run Replace against your own library.

Tick each line in the release notes (copy this list into the tag's PR).

**Background continuation and expiry**

- [ ] Queue three videos, start the run and lock the phone or switch apps. The system shows the continued-processing task
  (progress in the Live Activity and the system's task UI) and the run keeps going.
- [ ] Open the app again mid-run: progress is where it should be, nothing restarted.
- [ ] Cancel the system task from its own UI (or let the grant expire by leaving it long enough on a long queue): the
  running job returns to the queue, no partial file shows in Files or Photos, the original is untouched, and the
  queue is paused with a clear message. Resume finishes it.
- [ ] Force-quit the app mid-encode, reopen it: the job is queued again and restarts; no partial output remains in
  Work or in the output folder.

**Live Activity**

- [ ] The Lock Screen and the Dynamic Island show the current item, progress and the queue count while running.
- [ ] It updates about once a second (not faster), and ends on finish, on Cancel All and on Pause.
- [ ] With Live Activities turned off for the app in Settings, the app still runs and doesn't warn or crash.

**Battery, thermal and Low Power Mode**

- [ ] Low Power Mode on: the run slows to one video at a time without pausing, and turning it off restores the speed
  setting's limit.
- [ ] Battery at 20 % or less and unplugged: the queue shows the low-battery warning in the Queue and Live Activity and
  keeps running; plugging in or charging past 25 % clears it.
- [ ] Heat: convert a long batch in a warm room or with the phone in the sun. At Serious the queue slows to one job; at
  Critical it holds and says why. No job fails because of the hold.
- [ ] Energy Log: run Instruments' Energy Log (or the Xcode Energy gauge) over a 10-minute batch and confirm the app is not
  "Very High" while idle and that the work stops when the queue empties (PERFORMANCE.md).

**Share sheet, widget and Control**

- [ ] Share a video from Photos and from Files to the app: the extension shows the confirmation within a second or two,
  skips non-videos with a count, and "Open" opens the app with the video in the library. Share a 2 GB+ video and 20
  videos at once: the extension stays responsive and isn't killed (memory cap).
- [ ] Home Screen widget, small and medium: shows space saved and the queue count, and changes when the queue changes
  without polling (add a video, finish one).
- [ ] Control Center control: pause and resume with the app in the foreground, in the background and **not running**.
  Toggle it with the app force-quit, then open the app: the control's state wins (the queue opens paused or running as
  the control left it).

**Replace to Recently Deleted (test assets only)**

- [ ] Convert two test videos from Photos with Replace on. The smaller copies are saved and verified first. The bar
  "Move 2 Originals to Recently Deleted…" appears in the foreground only, one system confirmation covers the batch, and
  declining it leaves both originals and both copies.
- [ ] After confirming, the originals are in Recently Deleted (restore one to prove it), the copies are in the library with
  the metadata (date, location, camera) intact.
- [ ] Limited Photos access: assets outside the limited set stay pending and are never touched. Denied access shows the
  native state and downloads nothing.

**Adaptive layout (deferred: the UI test matrix is iPhone only for now; iPad and Duo come later, and the Simulator can't fold a Duo or enter split view)**

- [ ] iPad, split view and Slide Over at every width: the selection, an open sheet and a running job survive resizing.
- [ ] iPhone Duo Simulator (iOS 27.1) postures, by hand with Hardware ▸ Device ▸ Posture (or the Simulator's posture
  control): folded (outer screen, compact stack), half-open and open (inner screen, sidebar + detail). In each, switch
  posture while a job runs and while an inspector or Settings is open: nothing reloads, nothing restarts, and the
  selection is unchanged. The UI tests don't cover the iPad or the Duo yet (deferred); when they return, the Duo runs at its default posture because XCUITest can't set a posture.
- [ ] Dynamic Type at AX3 and AX5, light and dark, on the phone: no clipped or unreachable control.

**Gate**

The `v0.1.0` tag needs **both apps green in CI** (the Mac and iOS jobs, the sanitizers) **and** this checklist done.
The performance checks above (Mac) and in `PERFORMANCE.md` (iOS, `scripts/ios-ui-tests.sh --perf`) are also run first.

## Each release

1. Update `CHANGELOG.md`: give the version a section `## [X.Y.Z] - YYYY-MM-DD`.
2. Bump the version and commit:

   ```sh
   scripts/bump-version.sh X.Y.Z
   git commit -am "chore: release X.Y.Z"
   git push
   ```

3. Tag and push. The tag message becomes the release notes in the app's update window and on the Release page; a
   message that is just the version falls back to the CHANGELOG section.

   ```sh
   git tag -a vX.Y.Z -m "What changed, in a few lines"
   git push origin vX.Y.Z
   ```

4. Watch the Release workflow. When it finishes, the DMG is on the Release page and `appcast.xml` lists the new
   version; installed copies find it at their next check, or at once with Check for Updates….

## When something fails

- **Tag does not match MARKETING_VERSION:** delete the tag (`git push --delete origin vX.Y.Z`, `git tag -d vX.Y.Z`),
  run `scripts/bump-version.sh`, commit, and tag again.
- **SPARKLE_ED_PRIVATE_KEY is not set / APP_UPDATE_PUBLIC_KEY is empty:** finish the one-time setup above.
- **No matching signature in appcast.xml:** the public key in `Config/macOS.xcconfig` is not the one that belongs to the
  secret. Fix whichever is wrong; never generate new keys once a release is out, because installed copies only trust
  the key they shipped with.
- Re-running a failed workflow is safe: the DMG upload replaces the asset and the appcast item for the same build is
  updated, not duplicated.
