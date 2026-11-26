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
   cd Packages/AppModules
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
