#!/bin/bash

# Build Flow and launch the app bundle from the repository.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"

CONFIGURATION="${1:-debug}"
validate_configuration "$CONFIGURATION"
require_command open

"$SCRIPT_DIR/build.sh" "$CONFIGURATION"
open "$APP_BUNDLE"

echo "launched $APP_BUNDLE"
