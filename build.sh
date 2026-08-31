#!/bin/bash
# Builds Flow.app. No Xcode required: SwiftPM compiles the binary, we assemble the
# bundle by hand and ad-hoc sign it so TCC will grant mic and accessibility.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Flow.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Flow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Flow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer the local "Flow Dev" identity from ./make-cert.sh.
#
# This matters more than it looks. An ad-hoc signature's designated requirement is
# `cdhash H"…"`, a hash of the binary, so every rebuild looks like a different app to
# macOS and silently invalidates your Accessibility and Microphone grants — the toggles
# stay on in System Settings while the checks return false. A certificate-backed
# requirement is stable across rebuilds, so the grants stick.
if security find-certificate -c "Flow Dev" flow-dev.keychain >/dev/null 2>&1; then
	# The dedicated keychain is commonly locked after login. In that state the
	# certificate is visible, but codesign fails with errSecInternalComponent.
	# Unlock it with the local-development password created by make-cert.sh and
	# tell codesign exactly where to find the private key.
	security unlock-keychain -p "flow-local" flow-dev.keychain
	SIGN_ARGS=(--sign "Flow Dev" --keychain flow-dev.keychain)
else
	SIGN_ARGS=(--sign -)
	echo "note: signing ad-hoc. Run ./make-cert.sh once so permissions survive rebuilds."
fi

codesign --force "${SIGN_ARGS[@]}" \
	--identifier sh.taf.flow \
	--entitlements Resources/Flow.entitlements \
	--options runtime \
	"$APP"

# Never report a successful build for an app bundle macOS will reject.
codesign --verify --deep --strict "$APP"

echo "built $APP"

# Install to /Applications, replacing whatever is there.
#
# Two copies of Flow with the same bundle identifier is not a tidiness problem, it is a
# permissions problem: TCC keys a grant to identifier + certificate, so an older copy
# signed by a certificate you no longer have will hold the Accessibility grant while the
# copy you just built reads it as missing. The toggle sits there enabled and nothing
# works. Installing every build keeps exactly one copy on disk.
#
# Opt-in: FLOW_INSTALL=1 ./build.sh. Off by default so a build leaves exactly one copy
# on disk, the one in build/.
if [ "${FLOW_INSTALL:-0}" = "1" ]; then
	DEST="/Applications/Flow.app"

	# A running copy holds its bundle open, and relaunching is what picks up the build.
	WAS_RUNNING=""
	if pgrep -f "$DEST/Contents/MacOS/Flow" >/dev/null 2>&1; then
		WAS_RUNNING=1
		osascript -e 'tell application "Flow" to quit' >/dev/null 2>&1 || true
		# Give it a moment to go down cleanly before insisting.
		for _ in 1 2 3 4 5; do
			pgrep -f "$DEST/Contents/MacOS/Flow" >/dev/null 2>&1 || break
			sleep 0.4
		done
		pkill -f "$DEST/Contents/MacOS/Flow" >/dev/null 2>&1 || true
	fi

	rm -rf "$DEST"
	# ditto, not cp: it preserves the bundle's signature intact.
	ditto "$APP" "$DEST"
	codesign --verify --deep --strict "$DEST"
	echo "installed $DEST"

	if [ -n "$WAS_RUNNING" ]; then
		open "$DEST"
		echo "relaunched Flow"
	fi
fi
