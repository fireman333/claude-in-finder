#!/bin/bash
# Packages the built app into a distributable .dmg.
#
# The app is ad-hoc signed, not notarised, so anything downloaded from GitHub
# arrives quarantined and Gatekeeper refuses to open it. The DMG therefore ships
# a terminal installer rather than a drag-to-Applications target: running the
# script through bash sidesteps the quarantine prompt, and the installer clears
# the flag on its own copy of the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Sources/CCFKit/Update.swift is the single source of truth: the app reports the
# same number it compares against GitHub, so an update check cannot be fooled by
# a bundle that was stamped with a stale default.
VERSION="${VERSION:-$(sed -n 's/.*static let value = "\(.*\)".*/\1/p' "$ROOT/Sources/CCFKit/Update.swift" | head -1)}"
APP_NAME="Claude in Finder"
VOL_NAME="Claude in Finder"
DMG="$ROOT/dist/Claude-in-Finder-$VERSION.dmg"

VERSION="$VERSION" bash "$ROOT/Scripts/build.sh"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$ROOT/build/$APP_NAME.app" "$STAGE/"
cp "$ROOT/Scripts/install-app.sh" "$STAGE/install.sh"
cp "$ROOT/Scripts/uninstall.sh"   "$STAGE/uninstall.sh"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"

cat > "$STAGE/安裝說明 · INSTALL.txt" <<TXT
Claude in Finder $VERSION
=========================

這個 app 是自行簽章（ad-hoc signed）、沒有經過 Apple 公證（notarization），
所以從網路下載後 macOS 會擋下來。用下面的終端機指令安裝即可繞過，
不需要 sudo，所有東西都裝在你的家目錄底下。

安裝（打開「終端機」，貼上這一行，按 Enter）
---------------------------------------------

    bash "/Volumes/$VOL_NAME/install.sh"


就這樣。裝完之後：

  • 打開 ~/Claude Sessions
  • 雙擊任何一個 session → 在 Claude Code desktop 重新開啟
  • 按空白鍵 → Quick Look 直接預覽對話內容
  • 在 Claude 裡改 session 名稱 → 檔名會自動跟著改
  • 雙擊「+ New Session」→ 在那個專案開新對話
  • 對任何資料夾按右鍵 → 服務 → New Claude Session Here

有問題就跑：

    ccfinder doctor

（如果 ccfinder 找不到，把 ~/.local/bin 加進 PATH，
  或直接用完整路徑 ~/.local/bin/ccfinder）


移除
----

    bash "/Volumes/$VOL_NAME/uninstall.sh"

移除不會動到 ~/Claude Sessions，那個資料夾請自行刪除。


為什麼不是拖進 Applications？
-----------------------------

因為除了 app 本身，還要註冊背景同步的 LaunchAgent 和 ccfinder 指令。
拖曳安裝只會複製 app，同步不會啟動。


-----------------------------------------------------------------

Claude in Finder $VERSION — English

This app is ad-hoc signed and not notarised, so macOS blocks it after
download. Install from Terminal instead — no sudo, everything stays
inside your home directory:

    bash "/Volumes/$VOL_NAME/install.sh"

Then open ~/Claude Sessions. Double-click a session to reopen it in
Claude Code desktop, press space to preview it, right-click any folder
and choose Services > "New Claude Session Here".

Diagnose with:  ccfinder doctor
Uninstall with: bash "/Volumes/$VOL_NAME/uninstall.sh"

TXT

mkdir -p "$ROOT/dist"
rm -f "$DMG"

echo "==> creating dmg"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo
echo "built: $DMG"
echo "size:  $(du -h "$DMG" | cut -f1)"
