#!/bin/bash
# Opt-in desktop check in an isolated Electron fixture. Supply an Electron runtime.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"
: "${FLOW_ELECTRON_PATH:?Set FLOW_ELECTRON_PATH to an Electron executable}"
CHECK_DIR="$(mktemp -d -t flow-electron)"
env -u ELECTRON_RUN_AS_NODE "$FLOW_ELECTRON_PATH" "$SCRIPT_DIR/fixtures/electron/main.cjs" "$CHECK_DIR" > "$CHECK_DIR/electron.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; rm -rf -- "$CHECK_DIR"' EXIT
for _ in {1..100}; do
    if [ -s "$CHECK_DIR/ready.json" ]; then break; fi
    sleep 0.1
done
if [ ! -s "$CHECK_DIR/ready.json" ]; then cat "$CHECK_DIR/electron.log"; exit 1; fi
"$APP_BUNDLE/Contents/MacOS/Flow" --check-electron-insertion "$CHECK_DIR"
cat "$CHECK_DIR/results.json"
python3 - "$CHECK_DIR/results.json" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1]))['passed'] else 1)
PY
