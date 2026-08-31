#!/bin/bash

# Run the reproducible build and application-level self-check suite.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"

require_command swift

cd "$PROJECT_ROOT"
swift package clean

BUILD_LOG="$(mktemp)"
trap 'rm -f -- "$BUILD_LOG"' EXIT
swift build --configuration debug 2>&1 | tee "$BUILD_LOG"

if grep -E '(^|: )warning:' "$BUILD_LOG" >/dev/null; then
    echo "error: the debug build emitted compiler warnings" >&2
    exit 1
fi

"$SCRIPT_DIR/build.sh" debug
"$APP_BUNDLE/Contents/MacOS/Flow" --self-check
