#!/bin/bash
# Removes everything install.sh created. The mirror folder is left in place;
# delete ~/Claude Sessions by hand if you want it gone.
set -euo pipefail

LABEL="com.klaude.ccfinder"
APP="$HOME/Applications/Claude in Finder.app"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/.local/bin/ccfinder"
rm -rf "$APP"
rm -rf "$HOME/Library/Application Support/ClaudeInFinder"

# Drop our entries from the Services on/off list rather than leaving switches
# behind for services that no longer exist.
defaults export pbs - 2>/dev/null | python3 -c '
import plistlib, sys
prefs = plistlib.loads(sys.stdin.buffer.read())
statuses = prefs.get("NSServicesStatus", {})
for key in [k for k in statuses if "com.klaude.claude-in-finder" in k]:
    del statuses[key]
sys.stdout.buffer.write(plistlib.dumps(prefs))
' | defaults import pbs - 2>/dev/null || true
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

echo "Uninstalled. The mirror at ~/Claude Sessions was left untouched."
