#!/bin/bash
# README screenshots with made-up data. Runs a copy of the app renamed to
# sh.taf.flow.demo, so it has its own defaults, keeps history in memory, and never
# reads your dictations, vocabulary, or Keychain keys. It brings windows to the front,
# so leave the Mac alone for about 20 seconds.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"

"$SCRIPT_DIR/build.sh" debug >/dev/null
WORK="$(mktemp -d -t flow-screenshots)"
cleanup() {
    rm -rf -- "$WORK"
    defaults delete sh.taf.flow.demo >/dev/null 2>&1 || true
    rm -f -- "$HOME/Library/Preferences/sh.taf.flow.demo.plist"
}
trap cleanup EXIT
DEMO_APP="$WORK/Flow Demo.app"
cp -R "$APP_BUNDLE" "$DEMO_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier sh.taf.flow.demo" "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Flow" "$DEMO_APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$DEMO_APP" >/dev/null 2>&1
defaults delete sh.taf.flow.demo >/dev/null 2>&1 || true

"$DEMO_APP/Contents/MacOS/Flow" --demo-screenshots "$WORK/shots"
OUT="$PROJECT_ROOT/docs/images"
mkdir -p "$OUT"
for image in "$WORK"/shots/*.png; do
    name="$(basename "$image")"
    # Window captures are Retina, twice the window size. Half keeps the README light.
    # The pills are small, so they stay sharp at full size.
    case "$name" in
        pill-*) swift "$SCRIPT_DIR/support/trim-transparent.swift" "$image" "$OUT/$name" 32 >/dev/null ;;
        *)
            width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/ {print $2}')"
            sips --resampleWidth $((width / 2)) "$image" --out "$OUT/$name" >/dev/null
            ;;
    esac
done
ls -1 "$OUT"
