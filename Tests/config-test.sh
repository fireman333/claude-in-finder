#!/bin/bash
# Verifies the two user-facing settings actually change where files go.
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

echo "10. a live file that vanished without reaching the Trash is archived, never deleted"
#     it may have been dragged somewhere we do not look; archiving is undoable
"$CCFINDER" config on-delete delete >/dev/null
cat > "$CCF_SESSIONS/local_44444444-4444-4444-4444-444444444444.json" <<JSON
{"sessionId":"local_44444444-4444-4444-4444-444444444444",
 "cliSessionId":"44444444-4444-4444-4444-444444444444","cwd":"$WORKDIR",
 "title":"Fourth one","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000004000}
JSON
"$CCFINDER" sync >/dev/null
FOURTH="$WORKDIR/Claude Sessions/Fourth one.claudesession"
[ -f "$FOURTH" ] || fail "setup: Fourth one not mirrored"
OTHER="$TMP/moved-away"; mkdir -p "$OTHER"
mv "$FOURTH" "$OTHER/"
"$CCFINDER" sync >/dev/null
REC4="$CCF_SESSIONS/local_44444444-4444-4444-4444-444444444444.json"
[ -f "$REC4" ] || fail "an unconfirmed disappearance deleted the session"
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$REC4')).get('isArchived') is True else 1)" \
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

echo "12. deleting from inside Archive deletes for real, whatever the setting says"
"$CCFINDER" config on-delete archive >/dev/null      # the cautious setting
ARCHIVED="$WORKDIR/Claude Sessions/Archive/Third one.claudesession"
[ -f "$ARCHIVED" ] || fail "setup: Third one not in Archive"
rm "$ARCHIVED"
"$CCFINDER" sync >/dev/null
[ ! -f "$CCF_SESSIONS/local_33333333-3333-3333-3333-333333333333.json" ] \
  || fail "deleting from Archive did not delete the session"
[ -f "$CCF_SESSIONS/deleted_33333333-3333-3333-3333-333333333333" ] || fail "no tombstone"
[ -f "$CCF_SUPPORT/deleted/local_33333333-3333-3333-3333-333333333333.json" ] || fail "no backup"
[ ! -f "$ARCHIVED" ] || fail "the file came back"

echo "13. a deleted + New Session file stays deleted, for that folder only"
# earlier steps emptied the first project, and a folder with no sessions gets no
# + New Session file either
cat > "$CCF_SESSIONS/local_66666666-6666-6666-6666-666666666666.json" <<JSON
{"sessionId":"local_66666666-6666-6666-6666-666666666666",
 "cliSessionId":"66666666-6666-6666-6666-666666666666","cwd":"$WORKDIR",
 "title":"Still here","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000006000}
JSON
OTHER_W="$TMP/second-proj"; mkdir -p "$OTHER_W"
cat > "$CCF_SESSIONS/local_55555555-5555-5555-5555-555555555555.json" <<JSON
{"sessionId":"local_55555555-5555-5555-5555-555555555555",
 "cliSessionId":"55555555-5555-5555-5555-555555555555","cwd":"$OTHER_W",
 "title":"Neighbour","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000005000}
JSON
"$CCFINDER" sync >/dev/null
NEW1="$WORKDIR/Claude Sessions/+ New Session.claudesession"
NEW2="$OTHER_W/Claude Sessions/+ New Session.claudesession"
[ -f "$NEW1" ] && [ -f "$NEW2" ] || fail "setup: + New Session files missing"
rm "$NEW1"
"$CCFINDER" sync >/dev/null
[ ! -f "$NEW1" ] || fail "the deleted + New Session file came back"
[ -f "$NEW2" ] || fail "deleting one folder's file removed another folder's too"
"$CCFINDER" sync >/dev/null
[ ! -f "$NEW1" ] || fail "it came back on a later pass"

echo "14. turning the setting off removes them, and back on restores them all"
"$CCFINDER" config new-file hide >/dev/null
[ ! -f "$NEW2" ] || fail "hiding did not remove the + New Session files"
"$CCFINDER" config new-file show >/dev/null
[ -f "$NEW1" ] || fail "turning it back on did not restore the suppressed folder"
[ -f "$NEW2" ] || fail "turning it back on did not restore the other folder"

echo
echo "PASS — settings take effect immediately, hiding keeps the files,"
echo "       and deleting in Finder does what the setting says"
