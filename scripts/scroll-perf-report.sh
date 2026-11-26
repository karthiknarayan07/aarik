#!/usr/bin/env bash
# Prints the scroll metrics of an .xcresult and applies the thresholds (docs/testing/performance-and-device.md):
#   scripts/scroll-perf-report.sh RESULT.xcresult [--require-hitch]
# Fails (exit 1) when the average Hitch Time Ratio is over 5 ms/s, the number of hitches per iteration over 10, or the
# frame rate under 55 fps. The Simulator reports no hitch or frame-rate data, so without --require-hitch missing data
# is a note, not a failure; a device run passes --require-hitch.
set -euo pipefail
RESULT=${1:?usage: scroll-perf-report.sh RESULT.xcresult [--require-hitch]}
REQUIRE=${2:-}
xcrun xcresulttool get test-results metrics --path "$RESULT" | REQUIRE="$REQUIRE" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
values = {}
for test in data:
    for run in test.get("testRuns", []):
        for m in run.get("metrics", []):
            xs = m.get("measurements", [])
            if xs:
                values[m["displayName"]] = (sum(xs) / len(xs), m.get("unitOfMeasurement", ""))
for name, (avg, unit) in sorted(values.items()):
    print(f"  {name}: {avg:.3f} {unit}")
def get(prefix):
    for k, v in values.items():
        if k.startswith(prefix):
            return v[0]
ratio, hitches, fps = get("Hitch Time Ratio"), get("Number of Hitches"), get("Frame Rate")
problems = []
if ratio is None:
    print("  no hitch data (the Simulator does not produce any)")
    if os.environ.get("REQUIRE"):
        problems.append("no Hitch Time Ratio in the result")
else:
    if ratio > 5: problems.append(f"hitch time ratio {ratio:.2f} ms/s is over 5")
    if hitches is not None and hitches > 10: problems.append(f"{hitches:.0f} hitches per iteration is over 10")
if fps is not None and fps < 55: problems.append(f"frame rate {fps:.1f} fps is under 55")
for p in problems: print("  FAIL:", p)
sys.exit(1 if problems else 0)
'
