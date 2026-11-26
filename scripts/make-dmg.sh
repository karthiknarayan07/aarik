#!/usr/bin/env bash
# Builds the Release app, ad-hoc signs it and packs it into a compressed DMG.
# Output: build/dist/<product>-<version>.dmg
# BUILD_NUMBER, when set, overrides CURRENT_PROJECT_VERSION (CFBundleVersion); the release workflow passes its run
# number so every published build counts up.
# Names come from Config/Brand.xcconfig and the built Info.plist; nothing here names the brand.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD

project="Apps/macOS/Aarik.xcodeproj"
scheme="App"
brand_file="Config/Brand.xcconfig"

# Reads a KEY = value assignment from the brand file.
brand_value() {
  awk -F'=' -v key="$1" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      v = $2; sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit
    }' "$brand_file"
}

display_name=$(brand_value APP_DISPLAY_NAME)
product_name=$(brand_value APP_PRODUCT_NAME)
if [[ -z $display_name || -z $product_name ]]; then
  echo "make-dmg: APP_DISPLAY_NAME / APP_PRODUCT_NAME missing in $brand_file" >&2
  exit 1
fi

derived="$root/build/derived"
dist="$root/build/dist"
staging="$root/build/dmg-staging"

mkdir -p "$derived" "$dist"

overrides=(CODE_SIGNING_ALLOWED=NO)
if [[ -n ${BUILD_NUMBER:-} ]]; then
  if [[ ! $BUILD_NUMBER =~ ^[0-9]+$ ]]; then
    echo "make-dmg: BUILD_NUMBER must be a whole number, got '$BUILD_NUMBER'" >&2
    exit 1
  fi
  overrides+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

echo "==> Building $display_name (Release, arm64)"
xcodebuild -project "$project" -scheme "$scheme" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  "${overrides[@]}" build

app="$derived/Build/Products/Release/$product_name.app"
if [[ ! -d $app ]]; then
  echo "make-dmg: built app not found at $app" >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ -z $version ]]; then
  echo "make-dmg: CFBundleShortVersionString missing from built Info.plist" >&2
  exit 1
fi

echo "==> Ad-hoc signing"
codesign --force --deep -s - "$app"
codesign --verify --deep --strict "$app"

echo "==> Staging"
rm -rf "${staging:?}"
mkdir -p "$staging"
ditto "$app" "$staging/$product_name.app"
ln -s /Applications "$staging/Applications"

dmg="$dist/$product_name-$version.dmg"
rm -f "${dmg:?}"

echo "==> Creating $dmg"
hdiutil create -volname "$display_name" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"

rm -rf "${staging:?}"
echo "==> Done: $dmg"
