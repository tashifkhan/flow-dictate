#!/bin/bash
# Opt-in desktop check in a throwaway Firefox profile, on a local copy of Gemini's
# composer. Supply a Firefox-family app that is not already running, so the check can
# never type into your own browser windows.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd)/common.sh"
: "${FLOW_FIREFOX_APP:?Set FLOW_FIREFOX_APP to a Firefox app bundle, such as /Applications/Firefox Nightly.app}"
BUNDLE_ID="$(defaults read "$FLOW_FIREFOX_APP/Contents/Info" CFBundleIdentifier)"
if pgrep -f "$FLOW_FIREFOX_APP/Contents/MacOS" >/dev/null; then
    echo "error: $FLOW_FIREFOX_APP is running. Quit it, or point FLOW_FIREFOX_APP at another Firefox build." >&2
    exit 1
fi
CHECK_DIR="$(mktemp -d -t flow-firefox)"
mkdir -p "$CHECK_DIR/profile"
cat > "$CHECK_DIR/profile/user.js" <<'PREFS'
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.startup.page", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
PREFS
trap 'pkill -f "$FLOW_FIREFOX_APP/Contents/MacOS" 2>/dev/null || true; rm -rf -- "$CHECK_DIR"' EXIT
open -n -a "$FLOW_FIREFOX_APP" --args --no-remote --profile "$CHECK_DIR/profile" "file://$SCRIPT_DIR/fixtures/firefox/composer.html"
sleep 10
# The first Accessibility client switches Firefox's full accessibility on, which
# takes a few seconds before it reports a caret.
"$APP_BUNDLE/Contents/MacOS/Flow" --probe-focus "$BUNDLE_ID" "$CHECK_DIR/probe.json" >/dev/null
sleep 2
swift "$SCRIPT_DIR/support/click-focused-field.swift" "$BUNDLE_ID"
# Until then the check finds no tracked field and edits nothing, so it is safe to retry.
for attempt in 1 2 3 4; do
    sleep 3
    "$APP_BUNDLE/Contents/MacOS/Flow" --check-target-insertion "$BUNDLE_ID" "$CHECK_DIR/results.json"
    grep -q '"error" : "No tracked field"' "$CHECK_DIR/results.json" || break
done
cat "$CHECK_DIR/results.json"
python3 - "$CHECK_DIR/results.json" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1]))['passed'] else 1)
PY
