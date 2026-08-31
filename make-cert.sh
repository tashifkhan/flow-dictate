#!/bin/bash
# Creates a stable self-signed code-signing identity for local development.
#
# Why this exists: an ad-hoc signature (`codesign -s -`) has a designated requirement
# of `cdhash H"…"` — a hash of the binary's contents. Every rebuild changes it, so
# macOS treats each build as a brand-new app and every TCC grant you gave (Accessibility,
# Microphone) silently stops applying: the toggle stays on in System Settings while
# AXIsProcessTrusted() returns false.
#
# Signing with a certificate gives a requirement keyed to the certificate and the bundle
# identifier, which is stable across rebuilds, so grants persist.
#
# The identity lives in its own keychain so this needs no login-keychain password. Its
# password is not a secret — the key it protects only ever signs your local builds.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Flow Dev"
PASS="flow-local"
KEYCHAIN="$HOME/Library/Keychains/flow-dev.keychain-db"
KEYCHAIN_NAME="flow-dev.keychain"

# Note: `find-identity -p codesigning` reports this as invalid because the root is not
# in the trust store. That is expected for a local identity and does not stop codesign,
# so existence is checked against the certificate itself.
if security find-certificate -c "$NAME" "$KEYCHAIN_NAME" >/dev/null 2>&1; then
	echo "identity '$NAME' already available — nothing to do"
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
	-config "$TMP/openssl.cnf" 2>/dev/null

# macOS's Security framework only reads PKCS#12 written with the legacy PBE
# algorithms, and rejects an empty password, so both are pinned here.
openssl pkcs12 -export -legacy \
	-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
	-inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
	-name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"

[ -f "$KEYCHAIN" ] || security create-keychain -p "$PASS" "$KEYCHAIN_NAME"
security set-keychain-settings "$KEYCHAIN_NAME"          # no lock timeout
security unlock-keychain -p "$PASS" "$KEYCHAIN_NAME"
security import "$TMP/identity.p12" -k "$KEYCHAIN_NAME" -P "$PASS" -A -T /usr/bin/codesign

# Let codesign use the key without prompting, and make the keychain searchable.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN_NAME" >/dev/null 2>&1 || true
EXISTING=$(security list-keychains -d user | sed 's/[":]//g' | xargs)
case "$EXISTING" in
	*flow-dev*) ;;
	*) security list-keychains -d user -s $EXISTING "$KEYCHAIN_NAME" ;;
esac

echo
echo "created identity '$NAME'."
echo "Rebuild with ./build.sh — it picks this up automatically."
echo
echo "The signature changed, so clear the stale permission entries once:"
echo "  tccutil reset Accessibility sh.taf.flow"
echo "  tccutil reset Microphone sh.taf.flow"
echo "Then grant them again. They will stick across rebuilds from now on."
