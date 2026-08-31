#!/bin/bash

# Install Flow from a temporary clone for the README's curl command.
set -euo pipefail

REPOSITORY_URL="${FLOW_REPOSITORY_URL:-https://github.com/tashifkhan/flow-dictate.git}"
BRANCH="${FLOW_BRANCH:-main}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: Flow requires macOS" >&2
    exit 1
fi

for COMMAND in git swift; do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        echo "error: required command '$COMMAND' was not found" >&2
        exit 1
    fi
done

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flow-install.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

echo "downloading Flow"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    BASIC_AUTH="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64)"
    git -c "http.extraHeader=Authorization: Basic $BASIC_AUTH" \
        clone --quiet --depth 1 --branch "$BRANCH" "$REPOSITORY_URL" "$TEMP_DIR/dictate"
else
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPOSITORY_URL" "$TEMP_DIR/dictate"
fi
cd "$TEMP_DIR/dictate"

scripts/make-cert.sh
scripts/install.sh
