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

# macOS hides third-party services from the Finder context menu until they are
# explicitly enabled; a freshly installed service is simply absent from
# NSServicesStatus and therefore never drawn. Opt ours in.
#
# The values have to be real booleans, which the old-style plist syntax that
# `defaults -dict-add` accepts cannot express, so round-trip the domain through
# export/import instead of editing the file behind cfprefsd's back.
echo "==> enabling Finder services"
defaults export pbs - 2>/dev/null | python3 -c '
import plistlib, sys

data = sys.stdin.buffer.read()
prefs = plistlib.loads(data) if data.strip() else {}
statuses = prefs.setdefault("NSServicesStatus", {})

for title, message in [
    ("New Claude Session Here", "newSessionHere"),
    ("Archive Claude Session", "archiveSession"),
    ("Delete Claude Session", "deleteSession"),
    ("Open Claude Archive Folder", "openArchiveFolder"),
    ("Claude in Finder Settings\u2026", "openSettingsService"),
]:
    statuses[f"com.klaude.claude-in-finder - {title} - {message}"] = {
        "enabled_context_menu": True,
        "enabled_services_menu": True,
        "presentation_modes": {"ContextMenu": True, "ServicesMenu": True},
    }

sys.stdout.buffer.write(plistlib.dumps(prefs))
' | defaults import pbs -

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
/System/Library/CoreServices/pbs -update 2>/dev/null || true

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

# Ask for the protected folders now. macOS raises its prompts on first access, and
# an ad-hoc signed app loses its grants on every rebuild, so this has to happen on
# each install rather than once ever.
echo "==> checking access to protected folders"
"$DEST_APP/Contents/MacOS/ccfinder-open" --request-access 2>/dev/null || true

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
