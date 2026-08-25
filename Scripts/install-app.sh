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
# Deliberately not re-signed: cp -R preserves the signatures, and a --deep
# re-sign here would strip the sandbox entitlement off the Finder extension,
# which is the one thing that makes it register at all.

echo "==> registering with LaunchServices"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST_APP"

echo "==> linking CLI to $BIN_DIR/ccfinder"
mkdir -p "$BIN_DIR"
ln -sf "$DEST_APP/Contents/Resources/ccfinder" "$BIN_DIR/ccfinder"

# Register and switch on the Finder Sync extension. Its menu items appear in the
# contextual menu itself, rather than buried in the Services submenu, and it is
# the only way to get a menu when right-clicking the background of a window.
echo "==> enabling the Finder extension"
EXT="$DEST_APP/Contents/PlugIns/ClaudeFinderSync.appex"
if [ -d "$EXT" ]; then
  pluginkit -a "$EXT" 2>/dev/null || true
  pluginkit -e use -i "com.klaude.claude-in-finder.findersync" 2>/dev/null || true
fi

# Earlier versions put these in the Services submenu. The extension supersedes
# them, so drop the leftover switches rather than leaving dead entries behind.
defaults export pbs - 2>/dev/null | python3 -c '
import plistlib, sys
prefs = plistlib.loads(sys.stdin.buffer.read())
statuses = prefs.get("NSServicesStatus", {})
for key in [k for k in statuses if "com.klaude.claude-in-finder" in k]:
    del statuses[key]
sys.stdout.buffer.write(plistlib.dumps(prefs))
' | defaults import pbs - 2>/dev/null || true
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

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
    <string>$DEST_APP/Contents/MacOS/ccfinder-open</string>
    <string>--watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- Interactive, not Background: the agent owns the menu bar item, and a
       Background job is throttled and not treated as part of the GUI session. -->
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Application Support/ClaudeInFinder/ccfinder.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Application Support/ClaudeInFinder/ccfinder.log</string>
</dict>
</plist>
PLIST

# bootout is asynchronous, and the agent is an AppKit process that does not
# reliably act on SIGTERM — booting out alone left the old binary running, so an
# update appeared to change nothing at all. kickstart -k kills it outright and
# starts the job again, which is what actually swaps the binary.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
for _ in $(seq 1 20); do
  launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done
pkill -f "Claude in Finder.app/Contents/MacOS/ccfinder-open" 2>/dev/null || true

launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null || true
launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null || true

if ! launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  echo "error: the sync agent did not come up; run 'ccfinder doctor' for details." >&2
  exit 1
fi

# Finder loads extensions at launch, so a fresh install has none until it is
# restarted. Relaunching it is routine — windows reopen — and skipping it means
# the menu items appear to have not installed at all.
echo "==> restarting Finder so it picks up the extension"
killall Finder 2>/dev/null || true

echo "==> checking access to protected folders"
"$DEST_APP/Contents/MacOS/ccfinder-open" --request-access 2>/dev/null || true

echo "==> first sync"
"$DEST_APP/Contents/Resources/ccfinder" sync

# Report what still needs a human, rather than declaring success and leaving the
# user to discover a silently missing piece.
PENDING="$("$DEST_APP/Contents/Resources/ccfinder" doctor 2>/dev/null | grep "^❌" || true)"

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

if [ -n "$PENDING" ]; then
  cat <<PENDING_MSG

Needs your attention:

$PENDING

  • Folder access: System Settings > Privacy & Security > Full Disk Access,
    allow "Claude in Finder". Needed after every update — the app is ad-hoc
    signed, so a new build is a different app as far as macOS is concerned.
  • Finder menu: System Settings > General > Login Items & Extensions >
    Finder Extensions, switch on "Claude in Finder".

  Both are also reachable from the app's Settings window.
PENDING_MSG
fi
