#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"
CHECK_DIR="$(mktemp -d)"
python3 "$SCRIPT_DIR/fixtures/cloud_server.py" "$CHECK_DIR/port" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; rm -rf -- "$CHECK_DIR"' EXIT
for _ in {1..50}; do
    if [ -s "$CHECK_DIR/port" ]; then break; fi
    sleep 0.05
done
"$APP_BUNDLE/Contents/MacOS/Flow" --check-cloud-http "http://127.0.0.1:$(cat "$CHECK_DIR/port")/v1" "$CHECK_DIR/results.json"
cat "$CHECK_DIR/results.json"
