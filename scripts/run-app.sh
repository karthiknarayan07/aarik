#!/usr/bin/env bash
# Builds the macOS app (Debug) into .build/xcode and opens it.
# The product name comes from the build settings, so this script never names the brand.
set -euo pipefail

cd "$(dirname "$0")/.."

args=(-project App/App.xcodeproj -scheme App -configuration Debug -derivedDataPath .build/xcode)

xcodebuild "${args[@]}" build

settings=$(xcodebuild "${args[@]}" -showBuildSettings 2>/dev/null)
build_dir=$(awk -F' = ' '/^ *TARGET_BUILD_DIR = / { print $2; exit }' <<<"$settings")
product=$(awk -F' = ' '/^ *FULL_PRODUCT_NAME = / { print $2; exit }' <<<"$settings")

if [[ -z $build_dir || -z $product || ! -d "$build_dir/$product" ]]; then
  echo "run-app: built app not found (TARGET_BUILD_DIR='$build_dir', FULL_PRODUCT_NAME='$product')" >&2
  exit 1
fi

open "$build_dir/$product"
