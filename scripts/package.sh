#!/bin/bash

# Package Flow.app into a DMG, with optional Developer ID signing and notarization.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"

require_command diskutil

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG="$BUILD_DIR/Flow-${VERSION}.dmg"
STAGE="$BUILD_DIR/dmg"

"$SCRIPT_DIR/build.sh" release

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "signing with: $DEVELOPER_ID"
    codesign --force --deep --sign "$DEVELOPER_ID" \
        --identifier sh.taf.flow \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        "$APP_BUNDLE"
    codesign --verify --strict --verbose=2 "$APP_BUNDLE"
else
    echo "no DEVELOPER_ID set; Gatekeeper will warn on other Macs"
fi

rm -rf -- "$STAGE" "$DMG"
mkdir -p "$STAGE"
trap 'rm -rf -- "$STAGE"' EXIT
ditto "$APP_BUNDLE" "$STAGE/Flow.app"
ln -s /Applications "$STAGE/Applications"

diskutil image create from \
    --volumeName "Flow" \
    --format UDZO \
    "$STAGE" "$DMG" >/dev/null
rm -rf -- "$STAGE"
trap - EXIT
echo "built $DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    require_command xcrun
    if [[ -z "${DEVELOPER_ID:-}" ]]; then
        echo "error: notarization also requires DEVELOPER_ID" >&2
        exit 1
    fi
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "notarized and stapled $DMG"
fi
