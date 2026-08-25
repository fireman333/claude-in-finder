#!/bin/bash
# Installs an already-built "Claude in Finder.app" for the current user.
#
# Used both by Scripts/install.sh (after a source build) and by the installer
# shipped inside the DMG. Writes only inside $HOME; never needs sudo.
set -euo pipefail

APP_NAME="Claude in Finder"
LABEL="com.klaude.ccfinder"
SRC_APP="${1:-}"

if [ -z "$SRC_APP" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SRC_APP="$HERE/$APP_NAME.app"
fi

if [ ! -d "$SRC_APP" ]; then
  echo "error: cannot find $APP_NAME.app at $SRC_APP" >&2
  exit 1
fi

DEST_APP="$HOME/Applications/$APP_NAME.app"
BIN_DIR="$HOME/.local/bin"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> installing to $DEST_APP"
mkdir -p "$HOME/Applications"
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"

# Anything downloaded carries a quarantine flag; an ad-hoc signed app trips
# Gatekeeper because of it. Clearing it on our own copy is what makes the app
# launchable without a developer certificate.
echo "==> clearing quarantine flag"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$DEST_APP" 2>/dev/null || true

echo "==> registering with LaunchServices"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST_APP"

echo "==> linking CLI to $BIN_DIR/ccfinder"
mkdir -p "$BIN_DIR"
ln -sf "$DEST_APP/Contents/Resources/ccfinder" "$BIN_DIR/ccfinder"

echo "==> installing sync agent"
mkdir -p "$HOME/Library/Application Support/ClaudeInFinder" "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST_APP/Contents/Resources/ccfinder</string>
    <string>watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Application Support/ClaudeInFinder/ccfinder.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Application Support/ClaudeInFinder/ccfinder.log</string>
</dict>
</plist>
PLIST

# bootout is asynchronous: bootstrapping while the old job is still being torn
# down fails with "Input/output error". Wait for it to actually go away first.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
for _ in $(seq 1 40); do
  launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done

if ! launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null; then
  sleep 1
  if ! launchctl bootstrap "gui/$UID" "$AGENT"; then
    echo "error: could not start the sync agent." >&2
    echo "       try:  launchctl bootstrap gui/$UID \"$AGENT\"" >&2
    exit 1
  fi
fi

if ! launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  echo "error: the sync agent did not come up; run 'ccfinder doctor' for details." >&2
  exit 1
fi

echo "==> first sync"
"$DEST_APP/Contents/Resources/ccfinder" sync

cat <<DONE

Installed.

  Mirror     ~/Claude Sessions
  CLI        ccfinder  (add ~/.local/bin to PATH if it is not there yet)
  Agent      $LABEL  — syncing in the background

Open ~/Claude Sessions in Finder. Double-click a session to reopen it,
press space to preview it, or right-click a folder → Services →
"New Claude Session Here".

Run 'ccfinder doctor' if something looks wrong.
DONE
