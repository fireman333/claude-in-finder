#!/bin/bash
# Verifies the two user-facing settings actually change where files go.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCFINDER="$(swift build -c release --show-bin-path --package-path "$ROOT")/ccfinder"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CCF_SESSIONS="$TMP/sessions/acct/org"
export CCF_MIRROR="$TMP/central"
export CCF_INDEX="$TMP/index.json"
export CCF_SUPPORT="$TMP/support"
export CCF_TRASH="$TMP/trash"
mkdir -p "$CCF_TRASH"
mkdir -p "$CCF_SESSIONS"
WORKDIR="$TMP/proj"; mkdir -p "$WORKDIR"

write_session() {  # write_session <id> <title> <archived>
  cat > "$CCF_SESSIONS/local_$1.json" <<JSON
{"sessionId":"local_$1","cliSessionId":"$1","cwd":"$WORKDIR",
 "title":"$2","titleSource":"user","isArchived":$3,
 "createdAt":1780000000000,"lastActivityAt":1780000001000}
JSON
}
fail() { echo "FAIL: $1"; exit 1; }

write_session "11111111-1111-1111-1111-111111111111" "Live one" false
write_session "22222222-2222-2222-2222-222222222222" "Old one"  true

echo "1. defaults: working folder, archive shown"
"$CCFINDER" config >/dev/null
"$CCFINDER" sync >/dev/null
[ -f "$WORKDIR/Claude Sessions/Live one.claudesession" ] || fail "live session not in the working folder"
[ -f "$WORKDIR/Claude Sessions/Archive/Old one.claudesession" ] || fail "archived session not in Archive/"

echo "2. archive hide keeps the files but hides the folder"
"$CCFINDER" config archive hide >/dev/null
[ -f "$WORKDIR/Claude Sessions/Archive/Old one.claudesession" ] \
  || fail "hiding removed the archived session instead of hiding the folder"
ls -ldO "$WORKDIR/Claude Sessions/Archive" | grep -q hidden \
  || fail "the Archive folder is not marked hidden"
[ -f "$WORKDIR/Claude Sessions/Live one.claudesession" ] || fail "live session disappeared too"

echo "3. archive show reveals it again"
"$CCFINDER" config archive show >/dev/null
[ -f "$WORKDIR/Claude Sessions/Archive/Old one.claudesession" ] || fail "archived session vanished"
ls -ldO "$WORKDIR/Claude Sessions/Archive" | grep -q hidden \
  && fail "the Archive folder is still hidden" || true

echo "4. layout central moves everything under the central folder"
"$CCFINDER" config layout central >/dev/null
[ -f "$CCF_MIRROR/proj/Live one.claudesession" ] || fail "live session not moved to the central mirror"
[ -f "$CCF_MIRROR/proj/Archive/Old one.claudesession" ] || fail "archived session not under central Archive/"
[ ! -d "$WORKDIR/Claude Sessions" ] || fail "the working folder mirror was left behind"

echo "5. layout workdir moves them back"
"$CCFINDER" config layout workdir >/dev/null
[ -f "$WORKDIR/Claude Sessions/Live one.claudesession" ] || fail "live session did not return"
[ -f "$WORKDIR/Claude Sessions/Archive/Old one.claudesession" ] || fail "archived session did not return"

echo "6. settings persist to disk and are readable"
grep -q '"layout" : "workdir"' "$CCF_SUPPORT/config.json" || fail "layout not persisted"
"$CCFINDER" config | grep -q "layout       workdir" || fail "config summary wrong"

echo "7. a flag overrides the saved setting for one run only"
"$CCFINDER" sync --central >/dev/null
[ -f "$CCF_MIRROR/proj/Live one.claudesession" ] || fail "--central was ignored"
grep -q '"layout" : "workdir"' "$CCF_SUPPORT/config.json" || fail "--central changed the saved setting"

echo "8. deleting a file in Finder archives the session by default"
"$CCFINDER" config on-delete archive >/dev/null
LIVE="$WORKDIR/Claude Sessions/Live one.claudesession"
[ -f "$LIVE" ] || fail "setup: live session missing"
mv "$LIVE" "$CCF_TRASH/"          # what Finder does on delete
"$CCFINDER" sync >/dev/null
python3 -c "
import json,sys
d=json.load(open('$CCF_SESSIONS/local_11111111-1111-1111-1111-111111111111.json'))
sys.exit(0 if d.get('isArchived') is True else 1)" || fail "deleting the file did not archive the session"
[ -f "$WORKDIR/Claude Sessions/Archive/Live one.claudesession" ] \
  || fail "the session should reappear under Archive/"

echo "9. with on-delete=delete the record is removed instead"
"$CCFINDER" config on-delete delete >/dev/null
mv "$WORKDIR/Claude Sessions/Archive/Live one.claudesession" "$CCF_TRASH/"
"$CCFINDER" sync >/dev/null
[ ! -f "$CCF_SESSIONS/local_11111111-1111-1111-1111-111111111111.json" ] \
  || fail "the session record survived a delete-configured removal"
[ -f "$CCF_SESSIONS/deleted_11111111-1111-1111-1111-111111111111" ] || fail "no tombstone written"
[ -f "$CCF_SUPPORT/deleted/local_11111111-1111-1111-1111-111111111111.json" ] || fail "no backup kept"

echo "10. a file that vanished without reaching the Trash is archived, never deleted"
#     it may have been dragged somewhere we do not look; archiving is undoable
"$CCFINDER" config on-delete delete >/dev/null
OTHER="$TMP/moved-away"; mkdir -p "$OTHER"
mv "$WORKDIR/Claude Sessions/Archive/Old one.claudesession" "$OTHER/"
"$CCFINDER" sync >/dev/null
REC2="$CCF_SESSIONS/local_22222222-2222-2222-2222-222222222222.json"
[ -f "$REC2" ] || fail "an unconfirmed disappearance deleted the session"
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$REC2')).get('isArchived') is True else 1)" \
  || fail "it should have been archived instead"

echo "11. deleting without the Trash still archives (the common real case)"
#     Finder does not always leave a copy behind, and the sync agent may recreate
#     the file before it ever sees one; neither may stop the delete registering
"$CCFINDER" config on-delete archive >/dev/null
make_third() {
  cat > "$CCF_SESSIONS/local_33333333-3333-3333-3333-333333333333.json" <<JSON
{"sessionId":"local_33333333-3333-3333-3333-333333333333",
 "cliSessionId":"33333333-3333-3333-3333-333333333333","cwd":"$WORKDIR",
 "title":"Third one","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000003000}
JSON
}
make_third
"$CCFINDER" sync >/dev/null
THIRD="$WORKDIR/Claude Sessions/Third one.claudesession"
[ -f "$THIRD" ] || fail "setup: Third one not mirrored"
rm "$THIRD"                       # no Trash copy at all
"$CCFINDER" sync >/dev/null
python3 -c "
import json,sys
d=json.load(open('$CCF_SESSIONS/local_33333333-3333-3333-3333-333333333333.json'))
sys.exit(0 if d.get('isArchived') is True else 1)" || fail "a plain removal did not archive the session"
[ -f "$WORKDIR/Claude Sessions/Archive/Third one.claudesession" ] \
  || fail "it should have reappeared under Archive/"
[ ! -f "$THIRD" ] || fail "it was recreated in the live folder instead"

echo
echo "PASS — settings take effect immediately, hiding keeps the files,"
echo "       and deleting in Finder does what the setting says"
