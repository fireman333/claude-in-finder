#!/bin/bash
# Builds ccfinder (CLI) and assembles "Claude in Finder.app".
#
# Only the Command Line Tools are required — the app bundle is assembled by hand
# rather than by Xcode, and Quick Look is provided by the system's built-in HTML
# previewer via UTI conformance instead of by a preview extension.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
APP_NAME="Claude in Finder"
BUNDLE_ID="com.klaude.claude-in-finder"
UTI="com.klaude.claude-session"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

echo "==> swift build"
swift build -c release

BIN="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ccfinder-open" "$APP/Contents/MacOS/ccfinder-open"
cp "$BIN/ccfinder"      "$APP/Contents/Resources/ccfinder"
cp "$ROOT/Resources/AppIcon.icns"      "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/DocumentIcon.icns" "$APP/Contents/Resources/DocumentIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ccfinder-open</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>

  <!-- Our own file type. Conforming to public.html is what gives us a rich
       Quick Look preview for free: the system's Web.qlgenerator handles the
       preview, while LSHandlerRank=Owner keeps double-clicks pointed at us. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>$UTI</string>
      <key>UTTypeDescription</key><string>Claude Code Session</string>
      <key>UTTypeIconFile</key><string>DocumentIcon</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.html</string>
        <string>public.data</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>claudesession</string></array>
      </dict>
    </dict>
  </array>

  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Claude Code Session</string>
      <key>CFBundleTypeIconFile</key><string>DocumentIcon</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>$UTI</string></array>
    </dict>
  </array>

  <!-- Right-click a folder in Finder → Services → New Claude Session Here -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>New Claude Session Here</string></dict>
      <key>NSMessage</key><string>newSessionHere</string>
      <key>NSPortName</key><string>$APP_NAME</string>
      <key>NSSendFileTypes</key><array><string>public.folder</string></array>
      <key>NSSendTypes</key>
      <array>
        <string>NSFilenamesPboardType</string>
        <string>public.file-url</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for a locally built, non-quarantined app; there is no
# app extension here, which is precisely why no developer certificate is needed.
echo "==> codesign (ad-hoc)"
/usr/bin/codesign --force --deep --sign - "$APP"

echo
echo "built: $APP"
echo "cli:   $BIN/ccfinder"
