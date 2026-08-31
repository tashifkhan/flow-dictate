#!/bin/bash

# Shared paths and validation for Flow's developer scripts.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/Flow.app"
INFO_PLIST="$PROJECT_ROOT/AppBundle/Info.plist"
ENTITLEMENTS="$PROJECT_ROOT/AppBundle/Flow.entitlements"

readonly SCRIPT_DIR PROJECT_ROOT BUILD_DIR APP_BUNDLE INFO_PLIST ENTITLEMENTS

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required command '$1' was not found" >&2
        exit 1
    }
}

validate_configuration() {
    case "$1" in
        debug|release) ;;
        *)
            echo "error: configuration must be 'debug' or 'release'" >&2
            exit 2
            ;;
    esac
}
