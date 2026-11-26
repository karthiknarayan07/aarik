#!/usr/bin/env bash
# One command for the whole base gate: package tests, warnings-as-errors build, lint, Mac and iOS builds,
# iOS tests, brand-neutral and stale-path checks. Prints a pass/fail table; exits non-zero on any failure.
#
#   scripts/verify.sh [--only GROUP[,GROUP...]] [--repeat N]
#
# Groups: mac macui ios packages lint hygiene brand stale   (default: everything; macui is the Mac UI tests, also in mac)
# Env:    SIM_UDID (force a simulator), MAC_SCHEME (default App), IOS_SCHEME (default App-iOS),
#         VERIFY_DIR (logs and derived data, default .build/verify),
#         IOS_SKIP_TESTING (space-separated -skip-testing identifiers for "iOS app test", e.g. "AppUITests")
# Compatible with the bash 3.2 that ships with macOS.
set -uo pipefail
cd "$(dirname "$0")/.."
VERIFY_DIR=${VERIFY_DIR:-$PWD/.build/verify}
ONLY=""
REPEAT=1

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --only) ONLY=${2:?--only needs a group}; shift 2 ;;
    --only=*) ONLY=${1#--only=}; shift ;;
    --repeat) REPEAT=${2:?--repeat needs a number}; shift 2 ;;
    --repeat=*) REPEAT=${1#--repeat=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "verify: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ $REPEAT =~ ^[1-9][0-9]*$ ]] || { echo "verify: --repeat needs a positive integer" >&2; exit 2; }
for g in ${ONLY//,/ }; do
  case $g in mac|macui|ios|packages|lint|hygiene|brand|stale) ;; *) echo "verify: unknown group '$g'" >&2; exit 2 ;; esac
done

mkdir -p "$VERIFY_DIR/logs"
ROWS=()        # "run|check|status|seconds|log"
FAILED=0

selected() { # tags...: true when no --only, or any tag is requested
  [[ -z $ONLY ]] && return 0
  local t g
  for t in "$@"; do for g in ${ONLY//,/ }; do [[ $t == "$g" ]] && return 0; done; done
  return 1
}

# run RUN NAME "TAGS" CMD...: runs one check, logs it, records the row.
run() {
  local run=$1 name=$2 tags=$3; shift 3
  selected $tags || return 0
  local slug log start=$SECONDS status=PASS
  slug=$(echo "$name" | tr -c 'A-Za-z0-9\n' '-')
  log="$VERIFY_DIR/logs/run$run-$slug.log"
  printf '[run %s] %s ... ' "$run" "$name"
  if "$@" >"$log" 2>&1; then
    echo ok
  else
    status=FAIL; FAILED=1; echo FAILED
    tail -n 15 "$log" | sed 's/^/    | /'
  fi
  ROWS+=("$run|$name|$status|$((SECONDS - start))s|$log")
}
fail_check() { # RUN NAME "TAGS" MESSAGE: a check whose prerequisite is missing
  local run=$1 name=$2 tags=$3 msg=$4
  selected $tags || return 0
  echo "[run $run] $name ... FAILED: $msg"
  ROWS+=("$run|$name|FAIL|0s|$msg"); FAILED=1
}

# ---- discovery: packages by glob, apps at their fixed paths in App.xcworkspace ----
PACKAGES=()
while IFS= read -r p; do
  [[ -n $p ]] && PACKAGES+=("$(dirname "$p")")
done < <(find Packages -name Package.swift -not -path '*/.build/*' -not -path '*/checkouts/*' 2>/dev/null | sort)

WORKSPACE=App.xcworkspace
MAC_PROJECT=Apps/macOS/App.xcodeproj
IOS_PROJECT=Apps/iOS/App.xcodeproj
MAC_SCHEME=${MAC_SCHEME:-App}
IOS_SCHEME=${IOS_SCHEME:-App-iOS}

pick_simulator() { # prints a UDID: iPhone 17 Pro (newest runtime) if present, else the newest available iPhone
  if [[ -n ${SIM_UDID:-} ]]; then echo "$SIM_UDID"; return; fi
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
SIM=""
if selected ios; then SIM=$(pick_simulator 2>/dev/null || true); fi

lint_paths() {
  local p
  for p in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    [[ -d $p/Sources ]] && echo "$p/Sources"
    [[ -d $p/Tests ]] && echo "$p/Tests"
  done
  for p in Apps/macOS/Sources Apps/macOS/UITests Apps/Shared Apps/iOS; do [[ -d $p ]] && echo "$p"; done
}
brand_check() { # no product name in source, plists, project files or schemes
  local hits
  hits=$(grep -rIil aarik --include='*.swift' --include='*.plist' --include='*.pbxproj' --include='*.xcscheme' \
    --exclude-dir=.build --exclude-dir=checkouts Apps Packages 2>/dev/null || true)
  if [[ -n $hits ]]; then echo "product name found in:"; echo "$hits"; return 1; fi
}
stale_check() { # references to the old App/ layout outside history docs
  local hits
  hits=$(git grep -nE 'App/Sources|App/App\.xcodeproj|AppModules' -- . \
    ':!docs/superpowers' ':!docs/adr' ':!CHANGELOG.md' ':!scripts/verify.sh' 2>/dev/null || true)
  if [[ -n $hits ]]; then echo "stale layout references:"; echo "$hits"; return 1; fi
}
swift_test() { (cd "$1" && swift test); }
warnings_build() { (cd "$1" && swift build -Xswiftc -warnings-as-errors --build-tests); }
package_scheme() { # the SwiftPM umbrella scheme of the package in $1
  (cd "$1" && xcodebuild -list -json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = (d.get("workspace") or d.get("project") or {}).get("schemes", [])
print(next((x for x in s if x.endswith("-Package")), s[0] if s else ""))')
}
sim_test_package() {
  local dir=$1 scheme
  scheme=$(package_scheme "$dir")
  if [[ -z $scheme ]]; then echo "no scheme found for $dir"; return 1; fi
  (cd "$dir" && xcodebuild test -scheme "$scheme" -destination "id=$SIM" \
    -derivedDataPath "$VERIFY_DIR/derived-sim-$(basename "$dir")")
}
mac_build() { # CONFIG
  xcodebuild -workspace "$WORKSPACE" -scheme "$MAC_SCHEME" -configuration "$1" -derivedDataPath "$VERIFY_DIR/derived-mac" \
    -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
}
mac_ui_tests() { # the real app, driven by XCUITest; needs a signed runner (no CODE_SIGNING_ALLOWED=NO) and a logged-in desktop
  xcodebuild test -workspace "$WORKSPACE" -scheme "$MAC_SCHEME" -configuration Debug \
    -derivedDataPath "$VERIFY_DIR/derived-mac-ui" -destination 'platform=macOS,arch=arm64' \
    -only-testing:UITests -skip-testing:UITests/LaunchPerformanceTests
}
ios_xcode() { # ACTION
  local skip=() t
  if [[ $1 == test ]]; then for t in ${IOS_SKIP_TESTING:-}; do skip+=("-skip-testing:$t"); done; fi
  xcodebuild "$1" -workspace "$WORKSPACE" -scheme "$IOS_SCHEME" -derivedDataPath "$VERIFY_DIR/derived-ios" \
    -destination "id=$SIM" CODE_SIGNING_ALLOWED=NO ${skip[@]+"${skip[@]}"}
}

for ((n = 1; n <= REPEAT; n++)); do
  if [[ $REPEAT -gt 1 ]]; then echo "=== full run $n of $REPEAT ==="; fi

  if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    fail_check $n "find packages" "mac packages ios" "no Packages/**/Package.swift found"
  fi
  for p in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    run $n "swift test: $p" "mac packages" swift_test "$p"
    run $n "warnings-as-errors: $p" "mac packages" warnings_build "$p"
  done

  if [[ -z $SIM ]]; then
    fail_check $n "iOS simulator" ios "no available iPhone simulator in 'xcrun simctl list devices available -j'"
  else
    for p in ${PACKAGES[@]+"${PACKAGES[@]}"}; do run $n "iOS sim tests: $p" ios sim_test_package "$p"; done
  fi

  LP=()
  while IFS= read -r l; do [[ -n $l ]] && LP+=("$l"); done < <(lint_paths)
  if [[ ${#LP[@]} -eq 0 ]]; then
    fail_check $n "format lint" "mac lint" "no Sources or Tests directories found"
  else
    run $n "format lint" "mac lint" swift format lint --recursive --strict "${LP[@]}"
  fi

  if [[ ! -d $WORKSPACE || ! -d $MAC_PROJECT ]]; then
    fail_check $n "Mac build" mac "missing $WORKSPACE or $MAC_PROJECT"
  else
    run $n "Mac Debug build" mac mac_build Debug
    run $n "Mac Release build" mac mac_build Release
    run $n "Mac UI tests" "mac macui" mac_ui_tests
  fi

  if [[ ! -d $WORKSPACE || ! -d $IOS_PROJECT ]]; then
    fail_check $n "iOS app" ios "missing $WORKSPACE or $IOS_PROJECT"
  elif [[ -n $SIM ]]; then
    run $n "iOS app build" ios ios_xcode build
    run $n "iOS app test" ios ios_xcode test
  fi

  run $n "brand-neutral" "mac hygiene brand" brand_check
  run $n "stale paths" "mac hygiene stale" stale_check
done

echo
echo "==== verify summary ===="
printf '%-4s %-6s %-56s %s\n' run result check time
for r in ${ROWS[@]+"${ROWS[@]}"}; do
  IFS='|' read -r run name status secs log <<<"$r"
  printf '%-4s %-6s %-56s %s\n' "$run" "$status" "$name" "$secs"
  if [[ $status == FAIL ]]; then printf '       log: %s\n' "$log"; fi
done
if [[ $FAILED -eq 0 ]]; then echo "ALL PASSED ($REPEAT run(s))"; else echo "FAILED"; fi
exit $FAILED
