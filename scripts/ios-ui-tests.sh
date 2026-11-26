#!/usr/bin/env bash
# Runs the iOS UI tests (Apps/iOS/UITests) on one Simulator.
#
#   scripts/ios-ui-tests.sh [--udid UDID] [--perf] [--record-perf] [--record-snapshots] [--only Class[/test]]... [--build-only]
#
# Device: --udid, else $SIM_UDID, else iPhone 17 Pro if present, else the newest available iPhone. Always by UDID.
# Fixtures are generated, never anyone's own media: two heavy noisy clips (scripts/make-ui-fixture.swift) go into the
# Simulator's Photos library with `simctl addmedia`, one small clip goes to Files (On My iPhone) and one is staged by
# the hand-off test.
# Photos access is granted with `simctl privacy`. The Simulator library is not the owner's library.
#
# --perf runs the performance tests too (RUN_PERF_TESTS=1); --record-perf also rewrites Apps/iOS/UITests/Baselines.
# --record-snapshots rewrites the reference screenshots in Apps/iOS/UITests/References (record on the iPhone 17 only).
# Logs, derived data and result bundles go to .build/ios-ui.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID=${SIM_UDID:-}
PERF=0
RECORD=0
SNAPSHOTS=0
BUILD_ONLY=0
ONLY=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --udid) UDID=$2; shift 2 ;;
    --perf) PERF=1; shift ;;
    --record-perf) PERF=1; RECORD=1; shift ;;
    --record-snapshots) SNAPSHOTS=1; shift ;;
    --only) ONLY+=("-only-testing:UITests/$2"); shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    *) echo "ios-ui-tests: unknown argument $1" >&2; exit 2 ;;
  esac
done

OUT=.build/ios-ui
DERIVED=$OUT/derived
FIXTURES=$OUT/fixtures
mkdir -p "$OUT" "$FIXTURES" "$OUT/results"

pick_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devs = json.load(sys.stdin)["devices"]
best = None
for rt, items in devs.items():
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    if not m:
        continue
    ver = (int(m[1]), int(m[2]))
    for d in items:
        if not d["name"].startswith("iPhone") or not d.get("isAvailable", True):
            continue
        key = (d["name"] == "iPhone 17 Pro", ver)
        if best is None or key > best[0]:
            best = (key, d["udid"])
if best:
    print(best[1])
'
}
[[ -n $UDID ]] || UDID=$(pick_simulator)
[[ -n $UDID ]] || { echo "ios-ui-tests: no available iPhone simulator" >&2; exit 1; }
echo "ios-ui-tests: simulator $UDID"

# Fixtures: generated once, never personal media. The Photos clips are heavy noisy clips, because the Simulator's
# software encoder can't make a smooth clip 10 % smaller and the planner would keep it as is (clip-long runs long enough
# to be killed mid-encode); the clips for Files and the hand-off are small camera-metadata clips from devtool.
make_noisy() { [[ -f $FIXTURES/$1.mov ]] || swift scripts/make-ui-fixture.swift "$FIXTURES/$1.mov" "$2" 40 >/dev/null 2>&1; }
make_noisy clip-b 3
make_noisy clip-a 8
make_noisy clip-long 15
if [[ ! -f $FIXTURES/files-fixture.mov || ! -f $FIXTURES/handoff-fixture.mov ]]; then
  (cd Packages/Core && swift build --product devtool >/dev/null)
  DEVTOOL=$(cd Packages/Core && swift build --product devtool --show-bin-path)/devtool
  for name in files-fixture handoff-fixture; do
    rm -f "$FIXTURES/$name.mov"
    "$DEVTOOL" fixture "$FIXTURES/$name.mov" --seconds 3 --camera-metadata >/dev/null
  done
fi

# Build, then test without rebuilding so the install and the media are in place first.
xcodebuild build-for-testing -workspace App.xcworkspace -scheme App-iOS -derivedDataPath "$DERIVED" \
  -destination "id=$UDID" CODE_SIGNING_ALLOWED=NO >"$OUT/build.log" 2>&1 || {
  tail -30 "$OUT/build.log"; echo "ios-ui-tests: build failed (see $OUT/build.log)" >&2; exit 1; }
[[ $BUILD_ONLY -eq 0 ]] || exit 0

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name '*.app' -not -name '*Runner*' | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant photos "$BUNDLE"

# Each clip is added once per Simulator (a second addmedia would add a duplicate asset).
for clip in clip-a clip-b clip-long; do
  MARK=$OUT/photos-$clip-$UDID
  if [[ ! -f $MARK ]]; then
    xcrun simctl addmedia "$UDID" "$FIXTURES/$clip.mov"
    touch "$MARK"
  fi
done

# Files: the app's Documents folder shows in the Files picker as On My iPhone > <app name> (the app opts in with
# UIFileSharingEnabled), so a clip placed there is what the import test picks. (The local provider's own storage folder
# is not indexed by Files on current runtimes.)
DOCUMENTS=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Documents
mkdir -p "$DOCUMENTS"
cp "$FIXTURES/files-fixture.mov" "$DOCUMENTS/files-fixture.mov"

RESULT=$OUT/results/$UDID.xcresult
rm -rf "$RESULT"
export TEST_RUNNER_UI_FIXTURES="$PWD/$FIXTURES"
if [[ $SNAPSHOTS -eq 1 ]]; then export TEST_RUNNER_RECORD_SNAPSHOTS=1; fi
if [[ $PERF -eq 1 ]]; then export TEST_RUNNER_RUN_PERF_TESTS=1; fi
if [[ $RECORD -eq 1 ]]; then
  export TEST_RUNNER_RECORD_PERF_BASELINE=1
  export TEST_RUNNER_UI_BASELINE_OUT="$PWD/Apps/iOS/UITests/Baselines/baselines.json"
fi

set +e
xcodebuild test-without-building -workspace App.xcworkspace -scheme App-iOS -derivedDataPath "$DERIVED" \
  -destination "id=$UDID" -resultBundlePath "$RESULT" CODE_SIGNING_ALLOWED=NO ${ONLY[@]+"${ONLY[@]}"} >"$OUT/test.log" 2>&1
STATUS=$?
set -e
grep -E "error:|Test Case .*(passed|failed|skipped)|Executed [0-9]+ tests" "$OUT/test.log" | grep -v swiftc | cut -c1-300 || true
echo "ios-ui-tests: exit $STATUS (log $OUT/test.log, results $RESULT)"
exit $STATUS
