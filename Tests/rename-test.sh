#!/bin/bash
# Verifies the behaviour the whole tool hangs on: when a session is retitled in
# Claude Desktop, the mirrored file must be MOVED (keeping its Finder metadata),
# not deleted and recreated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCFINDER="$(swift build -c release --show-bin-path --package-path "$ROOT")/ccfinder"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CCF_SESSIONS="$TMP/sessions/acct/org"
export CCF_MIRROR="$TMP/mirror"
export CCF_INDEX="$TMP/index.json"
mkdir -p "$CCF_SESSIONS"

UUID="11111111-2222-3333-4444-555555555555"
write_session() {
  cat > "$CCF_SESSIONS/local_aaaa.json" <<JSON
{"sessionId":"local_aaaa","cliSessionId":"$UUID","cwd":"/tmp/demo-project",
 "title":"$1","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000001000,"model":"claude-opus-5"}
JSON
}

fail() { echo "FAIL: $1"; exit 1; }

echo "1. first sync creates the file"
write_session "Original title"
"$CCFINDER" sync >/dev/null
ORIG="$CCF_MIRROR/demo-project/Original title.claudesession"
[ -f "$ORIG" ] || fail "file not created at $ORIG"

echo "2. user metadata is attached (stands in for a Finder tag)"
xattr -w com.apple.metadata:_kCCFTest "marker" "$ORIG"
INODE_BEFORE="$(stat -f %i "$ORIG")"

echo "3. retitle in the desktop index, then re-sync"
write_session "Renamed title"
"$CCFINDER" sync >/dev/null

NEW="$CCF_MIRROR/demo-project/Renamed title.claudesession"
[ -f "$NEW" ] || fail "renamed file missing at $NEW"
[ ! -f "$ORIG" ] || fail "old filename still present"

echo "4. it was a move, not a recreate"
INODE_AFTER="$(stat -f %i "$NEW")"
[ "$INODE_BEFORE" = "$INODE_AFTER" ] || fail "inode changed ($INODE_BEFORE -> $INODE_AFTER): file was recreated, Finder tags would be lost"
xattr -p com.apple.metadata:_kCCFTest "$NEW" >/dev/null 2>&1 || fail "extended attribute lost"

echo "5. deep link resolves from the file"
"$CCFINDER" open --dry-run "$NEW" 2>/dev/null | grep -q "$UUID" \
  || fail "ccfinder open --dry-run did not report the session id"

echo "6. archiving removes it from the mirror"
python3 - "$CCF_SESSIONS/local_aaaa.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["isArchived"]=True
json.dump(d,open(p,"w"))
PY
"$CCFINDER" sync >/dev/null
[ ! -f "$NEW" ] || fail "archived session still mirrored"

echo "7. a lost index is rebuilt from the files themselves"
write_session "Back from archive"
"$CCFINDER" sync >/dev/null
BACK="$CCF_MIRROR/demo-project/Back from archive.claudesession"
[ -f "$BACK" ] || fail "unarchived session not restored"

rm -f "$CCF_INDEX"                       # simulate an uninstall/reinstall
write_session "Renamed with no index"
"$CCFINDER" sync >/dev/null
[ -f "$CCF_MIRROR/demo-project/Renamed with no index.claudesession" ] \
  || fail "rename after index loss did not happen"
[ ! -f "$BACK" ] \
  || fail "orphan left behind: the old filename survived an index loss"

echo
echo "PASS — rename is a move, metadata survives, archive prunes, index self-heals"
