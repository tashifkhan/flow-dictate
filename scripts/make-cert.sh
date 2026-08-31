#!/bin/bash

# Create the stable local identity used to keep TCC grants across rebuilds.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"

require_command openssl
require_command security

SIGNING_IDENTITY="${FLOW_SIGNING_IDENTITY:-Flow Dev}"
KEYCHAIN_PASSWORD="${FLOW_KEYCHAIN_PASSWORD:-flow-local}"
KEYCHAIN_NAME="${FLOW_KEYCHAIN_NAME:-flow-dev.keychain}"
KEYCHAIN_PATH="${FLOW_KEYCHAIN_PATH:-${HOME}/Library/Keychains/flow-dev.keychain-db}"

if security find-certificate -c "$SIGNING_IDENTITY" "$KEYCHAIN_NAME" >/dev/null 2>&1; then
    echo "identity '$SIGNING_IDENTITY' already available"
    exit 0
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

sed "s/__SIGNING_IDENTITY__/$SIGNING_IDENTITY/g" \
    "$SCRIPT_DIR/support/openssl-code-signing.cnf" > "$TEMP_DIR/openssl.cnf"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TEMP_DIR/key.pem" -out "$TEMP_DIR/cert.pem" \
    -config "$TEMP_DIR/openssl.cnf" 2>/dev/null

openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -inkey "$TEMP_DIR/key.pem" -in "$TEMP_DIR/cert.pem" \
    -name "$SIGNING_IDENTITY" -out "$TEMP_DIR/identity.p12" \
    -passout "pass:$KEYCHAIN_PASSWORD"

[[ -f "$KEYCHAIN_PATH" ]] || security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security set-keychain-settings "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security import "$TEMP_DIR/identity.p12" -k "$KEYCHAIN_NAME" \
    -P "$KEYCHAIN_PASSWORD" -A -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" >/dev/null 2>&1 || true

USER_KEYCHAINS=()
while IFS= read -r KEYCHAIN; do
    USER_KEYCHAINS+=("${KEYCHAIN//\"/}")
done < <(security list-keychains -d user)

case " ${USER_KEYCHAINS[*]} " in
    *"$KEYCHAIN_NAME"*) ;;
    *) security list-keychains -d user -s "${USER_KEYCHAINS[@]}" "$KEYCHAIN_NAME" ;;
esac

echo "created identity '$SIGNING_IDENTITY'"
echo "Run scripts/build.sh, then reset stale grants once:"
echo "  tccutil reset Accessibility sh.taf.flow"
echo "  tccutil reset Microphone sh.taf.flow"
