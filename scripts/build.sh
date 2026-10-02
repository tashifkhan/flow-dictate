#!/bin/bash

# Compile Flow, assemble its app bundle, and sign it for local use.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"

CONFIGURATION="${1:-release}"
validate_configuration "$CONFIGURATION"
require_command swift
require_command codesign
require_command security

cd "$PROJECT_ROOT"
swift build --configuration "$CONFIGURATION"
BINARY_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"

rm -rf -- "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
install -m 755 "$BINARY_DIR/Flow" "$APP_BUNDLE/Contents/MacOS/Flow"
install -m 644 "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# actool turns the Icon Composer file into AppIcon.icns plus the Liquid Glass Assets.car.
# It ships with Xcode, not the Command Line Tools, so a CLT-only build gets no icon.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool "$APP_ICON" \
        --compile "$APP_BUNDLE/Contents/Resources" \
        --app-icon AppIcon \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --output-partial-info-plist "$BUILD_DIR/AppIcon-partial.plist" >/dev/null
else
    echo "note: actool not found (needs Xcode); building without an app icon."
fi

SIGNING_IDENTITY="${FLOW_SIGNING_IDENTITY:-Flow Dev}"
KEYCHAIN_NAME="${FLOW_KEYCHAIN_NAME:-flow-dev.keychain}"
KEYCHAIN_PASSWORD="${FLOW_KEYCHAIN_PASSWORD:-flow-local}"

if security find-certificate -c "$SIGNING_IDENTITY" "$KEYCHAIN_NAME" >/dev/null 2>&1; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    SIGN_ARGS=(--sign "$SIGNING_IDENTITY" --keychain "$KEYCHAIN_NAME")
else
    SIGN_ARGS=(--sign -)
    echo "note: signing ad-hoc. Run scripts/make-cert.sh so permissions survive rebuilds."
fi

codesign --force "${SIGN_ARGS[@]}" \
    --identifier sh.taf.flow \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "built $APP_BUNDLE"

if [[ "${FLOW_INSTALL:-0}" == "1" ]]; then
    WAS_RUNNING=""

    if pgrep -f "$INSTALLED_APP/Contents/MacOS/Flow" >/dev/null 2>&1; then
        WAS_RUNNING=1
        osascript -e 'tell application "Flow" to quit' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
            pgrep -f "$INSTALLED_APP/Contents/MacOS/Flow" >/dev/null 2>&1 || break
            sleep 0.4
        done
        pkill -f "$INSTALLED_APP/Contents/MacOS/Flow" >/dev/null 2>&1 || true
    fi

    rm -rf -- "$INSTALLED_APP"
    ditto "$APP_BUNDLE" "$INSTALLED_APP"
    codesign --verify --deep --strict "$INSTALLED_APP"
    echo "installed $INSTALLED_APP"

    if [[ -n "$WAS_RUNNING" ]]; then
        open "$INSTALLED_APP"
        echo "relaunched Flow"
    fi
fi
