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

echo "Uninstalled. The mirror at ~/Claude Sessions was left untouched."
