#!/usr/bin/env bash
# Runs the Photos scroll performance test on a connected iPhone, against its real Photos library (read only: nothing
# is added, changed or converted), and applies the thresholds.
#
#   scripts/device-perf.sh [--udid UDID] [--seconds N] [--trace]
#
# Signing: Personal Team (override with DEVELOPMENT_TEAM). --trace also records a Time Profiler trace of the app while
# the test scrolls. Output goes to .build/device-perf: the log, the .xcresult and the .trace. Other scripts
# (device-smoke.sh) can call this one; it exits non-zero when the test fails or a threshold is passed.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID=${DEVICE_UDID:-}
SECONDS_PER_ITERATION=20
TRACE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --udid) UDID=$2; shift 2 ;;
    --seconds) SECONDS_PER_ITERATION=$2; shift 2 ;;
    --trace) TRACE=1; shift ;;
    *) echo "device-perf: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [[ -z $UDID ]]; then
  UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && /available|connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')
fi
[[ -n $UDID ]] || { echo "device-perf: no connected iPhone (xcrun devicectl list devices)" >&2; exit 1; }
echo "device-perf: device $UDID"

TEAM=${DEVELOPMENT_TEAM:-95J795334T}
OUT=.build/device-perf
mkdir -p "$OUT"
RESULT=$OUT/result-$(date +%H%M%S).xcresult
export TEST_RUNNER_RUN_PERF_TESTS=1 TEST_RUNNER_UI_FAKE_PHOTOS=0 TEST_RUNNER_UI_SCROLL_SECONDS=$SECONDS_PER_ITERATION

if [[ $TRACE -eq 1 ]]; then
  (
    # Wait for the app to be running, then profile it through the first measured iteration.
    PID=
    for _ in $(seq 1 150); do
      PID=$(xcrun devicectl device info processes --device "$UDID" 2>/dev/null | awk '/\/App.app\/App/ {print $1; exit}')
      [[ -n $PID ]] && break
      sleep 2
    done
    [[ -n $PID ]] || exit 0
    sleep 12
    xcrun xctrace record --template "Time Profiler" --device "$UDID" --attach "$PID" \
      --time-limit "${SECONDS_PER_ITERATION}s" --output "$OUT/scroll.trace" >"$OUT/xctrace.log" 2>&1 || true
  ) &
fi

set +e
xcodebuild test -workspace App.xcworkspace -scheme App-iOS -derivedDataPath "$OUT/derived" \
  -destination "id=$UDID" -resultBundlePath "$RESULT" -only-testing:UITests/PhotosScrollPerformanceTests \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_ENTITLEMENTS="" \
  -allowProvisioningUpdates >"$OUT/test.log" 2>&1
STATUS=$?
set -e
wait || true
grep -E "error:|PERF |Test Case .*(passed|failed|skipped)" "$OUT/test.log" | cut -c1-300 || true
[[ $STATUS -eq 0 ]] || { echo "device-perf: test run failed (log $OUT/test.log)" >&2; exit $STATUS; }
scripts/scroll-perf-report.sh "$RESULT" --require-hitch
