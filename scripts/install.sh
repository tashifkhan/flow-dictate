#!/bin/bash

# Build Flow, replace /Applications/Flow.app, verify it, and launch it.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"

CONFIGURATION="${1:-release}"
validate_configuration "$CONFIGURATION"
require_command open

FLOW_INSTALL=1 "$SCRIPT_DIR/build.sh" "$CONFIGURATION"
open "$INSTALLED_APP"

echo "Flow is installed in /Applications"
