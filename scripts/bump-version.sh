#!/usr/bin/env bash
# Sets MARKETING_VERSION in Config/macOS.xcconfig. Usage: scripts/bump-version.sh X.Y.Z
# The release workflow only accepts a tag vX.Y.Z that matches this value. The build number (CFBundleVersion) is not
# set here: the release workflow uses its run number.
set -euo pipefail

cd "$(dirname "$0")/.."

config="Config/macOS.xcconfig"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 64
fi
new=$1
# Plain X.Y.Z without leading zeros: CFBundleShortVersionString and Sparkle's version comparison both expect it.
if [[ ! $new =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "bump-version: '$new' is not a version of the form X.Y.Z (for example 0.2.0)" >&2
  exit 64
fi

count=$(grep -cE '^[[:space:]]*MARKETING_VERSION[[:space:]]*=' "$config" || true)
if [[ $count -ne 1 ]]; then
  echo "bump-version: expected exactly one MARKETING_VERSION line in $config, found $count" >&2
  exit 1
fi
old=$(awk '/^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print v }' "$config")
if [[ $old == "$new" ]]; then
  echo "bump-version: MARKETING_VERSION is already $new"
  exit 0
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/xcconfig.XXXXXX")
trap 'rm -f "$tmp"' EXIT
awk -v v="$new" '
  /^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ { print "MARKETING_VERSION = " v; next }
  { print }' "$config" > "$tmp"
cat "$tmp" > "$config"

echo "MARKETING_VERSION: $old -> $new"
echo "Next: update CHANGELOG.md, commit, then: git tag -a v$new -m \"<release notes>\" && git push origin v$new"
