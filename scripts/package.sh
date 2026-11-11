#!/bin/bash
# Builds AppVolume.app and packages it as a DMG and a ZIP.
#   VERSION, BUILD_NUMBER   written into Info.plist (default 1.0.0 / 1)
#   SIGN_IDENTITY           codesign identity (default "-", ad-hoc)
#   SIGN_KEYCHAIN           keychain holding the identity (optional)
#   WORK_DIR                intermediates (default ./.build)
#   DIST_DIR                where the DMG and ZIP go (default ./dist)
set -euo pipefail
cd "$(dirname "$0")/.."

version="${VERSION:-1.0.0}"
build_number="${BUILD_NUMBER:-1}"
identity="${SIGN_IDENTITY:--}"
work="${WORK_DIR:-$PWD/.build}"
dist="${DIST_DIR:-$PWD/dist}"
stage="$work/stage-$build_number"
iconset="$work/AppIcon-$build_number.iconset"
app="$stage/AppVolume.app"

swift build -c release --arch arm64 --scratch-path "$work/spm"
bin="$(swift build -c release --arch arm64 --scratch-path "$work/spm" --show-bin-path)/AppVolume"

if [ -e "$stage" ] || [ -e "$iconset" ]; then
  echo "$stage or $iconset already exists; use a new BUILD_NUMBER or a clean WORK_DIR" >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset" "$dist"
cp "$bin" "$app/Contents/MacOS/AppVolume"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
  -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" > /dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

sign=(codesign --force --sign "$identity" --timestamp=none)
[ -z "${SIGN_KEYCHAIN:-}" ] || sign+=(--keychain "$SIGN_KEYCHAIN")
"${sign[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"
codesign -dvv "$app" 2>&1 | grep -E '^(Identifier|Authority|Signature)' || true
plutil -lint "$app/Contents/Info.plist"

# The binary must at least start and talk to Core Audio. A hang is reported, not fatal: the
# build Mac may have no audio session.
"$app/Contents/MacOS/AppVolume" --self-test & pid=$!
( sleep 30; kill -9 "$pid" 2>/dev/null ) & watchdog=$!
status=0; wait "$pid" || status=$?
kill "$watchdog" 2>/dev/null || true
case "$status" in
  0) ;;
  137) echo "warning: self-test did not finish within 30 seconds" >&2 ;;
  *) echo "self-test failed with status $status" >&2; exit 1 ;;
esac

name="AppVolume-$version"
ditto -c -k --keepParent "$app" "$dist/$name.zip"
ln -s /Applications "$stage/Applications"
hdiutil create -volname AppVolume -srcfolder "$stage" -ov -format UDZO "$dist/$name.dmg"
[ "$identity" = "-" ] || "${sign[@]}" "$dist/$name.dmg"
(cd "$dist" && shasum -a 256 "$name.zip" "$name.dmg" | tee "$name.sha256")
