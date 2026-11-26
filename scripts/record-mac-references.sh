#!/usr/bin/env bash
# Re-records the Mac UI test reference screenshots into Apps/macOS/UITests/References/. Look at every image before
# committing it: they are what the pixel comparison holds the layout to.
#
#   scripts/record-mac-references.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERIFY_DIR=${VERIFY_DIR:-$PWD/.build/verify}
# The runner is sandboxed: it records into its own container, and the PNGs are copied from there.
CONTAINER="$HOME/Library/Containers/$(grep -m1 "^APP_BUNDLE_ID_PREFIX" Config/Brand.xcconfig | sed 's/.*= *//' | head -1).uitests.xctrunner/Data/tmp/ui-references"
rm -rf "$CONTAINER"
TEST_RUNNER_RECORD_SNAPSHOTS=1 xcodebuild test -workspace App.xcworkspace -scheme "${MAC_SCHEME:-App}" \
  -configuration Debug -derivedDataPath "$VERIFY_DIR/derived-mac-ui" -destination 'platform=macOS,arch=arm64' \
  -only-testing:UITests/ReferenceScreenshotTests
mkdir -p Apps/macOS/UITests/References
cp "$CONTAINER"/*.png Apps/macOS/UITests/References/
echo "Recorded $(ls "$CONTAINER" | wc -l | tr -d ' ') references into Apps/macOS/UITests/References/"
