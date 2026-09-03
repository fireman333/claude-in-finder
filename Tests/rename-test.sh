#!/bin/bash
# Verifies the behaviour the whole tool hangs on: when a session is retitled in
# Claude Desktop, the mirrored file must be MOVED (keeping its Finder metadata),
# not deleted and recreated. Also covers where files land, git hygiene, archiving
# and index recovery.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# --show-bin-path only prints the path, it does not build. Without this the
# whole suite silently exercises whatever binary was last compiled.
swift build -c release --package-path "$ROOT" >/dev/null
CCFINDER="$(swift build -c release --show-bin-path --package-path "$ROOT")/ccfinder"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CCF_SESSIONS="$TMP/sessions/acct/org"
export CCF_MIRROR="$TMP/central"
export CCF_INDEX="$TMP/index.json"
# isolate settings too, or the run picks up whatever the real install is set to
export CCF_SUPPORT="$TMP/support"
export CCF_TRASH="$TMP/trash"
mkdir -p "$TMP/trash"
mkdir -p "$CCF_SESSIONS"

WORKDIR="$TMP/demo-project"
mkdir -p "$WORKDIR"
UUID="11111111-2222-3333-4444-555555555555"

write_session() {  # write_session <title> [cwd]
  cat > "$CCF_SESSIONS/local_aaaa.json" <<JSON
{"sessionId":"local_aaaa","cliSessionId":"$UUID","cwd":"${2:-$WORKDIR}",
 "title":"$1","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000001000,"model":"claude-opus-5"}
JSON
}

fail() { echo "FAIL: $1"; exit 1; }

echo "1. the file lands inside the working directory, not the central mirror"
write_session "Original title"
"$CCFINDER" sync >/dev/null
ORIG="$WORKDIR/Claude Sessions/Original title.claudesession"
[ -f "$ORIG" ] || fail "expected $ORIG"

echo "2. user metadata is attached (stands in for a Finder tag)"
xattr -w com.apple.metadata:_kCCFTest "marker" "$ORIG"
INODE_BEFORE="$(stat -f %i "$ORIG")"

echo "3. retitle in the desktop index, then re-sync"
write_session "Renamed title"
"$CCFINDER" sync >/dev/null
NEW="$WORKDIR/Claude Sessions/Renamed title.claudesession"
[ -f "$NEW" ] || fail "renamed file missing at $NEW"
[ ! -f "$ORIG" ] || fail "old filename still present"

echo "4. it was a move, not a recreate"
INODE_AFTER="$(stat -f %i "$NEW")"
[ "$INODE_BEFORE" = "$INODE_AFTER" ] || fail "inode changed: file was recreated, Finder tags would be lost"
xattr -p com.apple.metadata:_kCCFTest "$NEW" >/dev/null 2>&1 || fail "extended attribute lost"

echo "5. deep link resolves from the file"
"$CCFINDER" open --dry-run "$NEW" 2>/dev/null | grep -q "$UUID" || fail "open --dry-run lost the session id"

echo "6. a git repository gets a local exclude, and no tracked file is touched"
git -C "$WORKDIR" init -q 2>/dev/null || fail "could not init test repo"
"$CCFINDER" sync >/dev/null
grep -q "^Claude Sessions/$" "$WORKDIR/.git/info/exclude" || fail "exclude rule not added"
[ -z "$(git -C "$WORKDIR" status --porcelain)" ] || fail "mirror files show up in git status"
"$CCFINDER" sync >/dev/null
[ "$(grep -c "^Claude Sessions/$" "$WORKDIR/.git/info/exclude")" = "1" ] || fail "exclude rule duplicated"

echo "7. a session whose working directory is gone still gets mirrored"
GONE="$TMP/deleted-project"
mkdir -p "$GONE"; write_session "Homeless session" "$GONE"; rm -rf "$GONE"
"$CCFINDER" sync >/dev/null
[ -f "$CCF_MIRROR/_Unavailable/deleted-project/Homeless session.claudesession" ] \
  || fail "session with a missing cwd was dropped"

echo "8. archiving moves the file into Archive/ instead of deleting it"
write_session "Back home"
"$CCFINDER" sync >/dev/null
BACK="$WORKDIR/Claude Sessions/Back home.claudesession"
[ -f "$BACK" ] || fail "session not restored to its working directory"
python3 - "$CCF_SESSIONS/local_aaaa.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["isArchived"]=True
json.dump(d,open(p,"w"))
PY
INODE_LIVE="$(stat -f %i "$BACK")"
"$CCFINDER" sync >/dev/null
ARCHIVED="$WORKDIR/Claude Sessions/Archive/Back home.claudesession"
[ -f "$ARCHIVED" ] || fail "archived session not found in Archive/"
[ ! -f "$BACK" ] || fail "archived session left in the live folder"
[ "$INODE_LIVE" = "$(stat -f %i "$ARCHIVED")" ] || fail "archiving recreated the file instead of moving it"
[ ! -f "$WORKDIR/Claude Sessions/Archive/+ New Session.claudesession" ] || fail "+ New Session leaked into Archive/"
[ ! -f "$WORKDIR/Claude Sessions/Archive/.ccf-project" ] || fail ".ccf-project leaked into Archive/"

echo "8b. --no-archived leaves them out entirely"
"$CCFINDER" sync --no-archived >/dev/null
[ ! -f "$ARCHIVED" ] || fail "--no-archived still mirrored an archived session"

echo "9. a lost index is rebuilt from the files themselves"
python3 - "$CCF_SESSIONS/local_aaaa.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["isArchived"]=False
json.dump(d,open(p,"w"))
PY
"$CCFINDER" sync >/dev/null
[ -f "$BACK" ] || fail "unarchived session not restored"
rm -f "$CCF_INDEX"                       # simulate an uninstall/reinstall
write_session "Renamed with no index"
"$CCFINDER" sync >/dev/null
[ -f "$WORKDIR/Claude Sessions/Renamed with no index.claudesession" ] || fail "rename after index loss did not happen"
[ ! -f "$BACK" ] || fail "orphan left behind: the old filename survived an index loss"

echo "9b. renaming the file in Finder renames the session, and creates nothing new"
write_session "Before rename"
"$CCFINDER" sync >/dev/null
FROM="$WORKDIR/Claude Sessions/Before rename.claudesession"
[ -f "$FROM" ] || fail "setup: file missing"
mv "$FROM" "$WORKDIR/Claude Sessions/After rename.claudesession"
"$CCFINDER" sync >/dev/null
[ -f "$WORKDIR/Claude Sessions/After rename.claudesession" ] || fail "the renamed file did not survive"
[ ! -f "$FROM" ] || fail "the old name was recreated alongside it"
python3 -c "
import json,sys
d=json.load(open('$CCF_SESSIONS/local_aaaa.json'))
sys.exit(0 if d.get('title')=='After rename' and d.get('titleSource')=='user' else 1)" \
  || fail "Claude's record was not renamed"
COUNT=$(ls -1 "$WORKDIR/Claude Sessions"/*.claudesession | grep -vc "New Session")
[ "$COUNT" = "1" ] || fail "expected one session file, found $COUNT"

echo "10. every 'new session' entry point resolves to the working directory"
write_session "Anchor"
"$CCFINDER" sync >/dev/null
EXPECT="claude://code/new?folder=$WORKDIR"
mkdir -p "$WORKDIR/Claude Sessions/Archive"
for target in \
  "$WORKDIR" \
  "$WORKDIR/Claude Sessions" \
  "$WORKDIR/Claude Sessions/+ New Session.claudesession" \
  "$WORKDIR/Claude Sessions/Anchor.claudesession"
do
  got="$("$CCFINDER" new "$target" --dry-run)"
  [ "$got" = "$EXPECT" ] || fail "new from '$target' gave $got, expected $EXPECT"
done
# the + New Session file itself must resolve the same way when opened
got="$("$CCFINDER" open "$WORKDIR/Claude Sessions/+ New Session.claudesession" --dry-run)"
[ "$got" = "$EXPECT" ] || fail "opening + New Session gave $got"

echo
echo "PASS — lands in the working directory, renames are moves, git stays clean,"
echo "       missing folders fall back, archiving prunes, the index self-heals"
