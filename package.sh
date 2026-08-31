#!/bin/bash
# Packages Flow.app into a DMG, optionally signed with a Developer ID and notarized.
#
#   ./package.sh                                  ad-hoc signed DMG, not notarized
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" ./package.sh
#   DEVELOPER_ID=... NOTARY_PROFILE=flow ./package.sh      sign, notarize, staple
#
# Store the notary profile once with:
#   xcrun notarytool store-credentials flow --apple-id you@example.com \
#         --team-id TEAMID --password APP-SPECIFIC-PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Flow.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/Flow-${VERSION}.dmg"
STAGE="build/dmg"

./build.sh release

# --- Signing -----------------------------------------------------------------
# The hardened runtime is required for notarization, and must be applied with a
# real identity; the ad-hoc signature from build.sh cannot be notarized.
if [[ -n "${DEVELOPER_ID:-}" ]]; then
	echo "signing with: $DEVELOPER_ID"
	codesign --force --deep --sign "$DEVELOPER_ID" \
		--identifier sh.taf.flow \
		--entitlements Resources/Flow.entitlements \
		--options runtime \
		--timestamp \
		"$APP"
	codesign --verify --strict --verbose=2 "$APP"
else
	echo "no DEVELOPER_ID set: keeping the local build signature."
	echo "  The DMG will build, but Gatekeeper will warn on other Macs."
	echo "  Right-click › Open works, or run: xattr -dr com.apple.quarantine /Applications/Flow.app"
fi

# --- DMG ---------------------------------------------------------------------
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
	-volname "Flow" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null
rm -rf "$STAGE"
echo "built $DMG"

# --- Notarization ------------------------------------------------------------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
	if [[ -z "${DEVELOPER_ID:-}" ]]; then
		echo "error: notarization needs DEVELOPER_ID as well; an ad-hoc signature is rejected." >&2
		exit 1
	fi
	echo "submitting for notarization, this takes a few minutes"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	# Stapling lets the DMG validate offline on the target Mac.
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
	echo "notarized and stapled: $DMG"
else
	echo "no NOTARY_PROFILE set: skipping notarization."
fi
