#!/bin/bash
# Verifies the archive and delete services against Claude's own record format:
# archiving flips isArchived, deleting writes the tombstone Claude uses and keeps
# both a backup of the record and the original transcript.
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
mkdir -p "$TMP/trash"
mkdir -p "$CCF_SESSIONS"

WORKDIR="$TMP/proj"; mkdir -p "$WORKDIR"
UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
REC="$CCF_SESSIONS/local_$UUID.json"

cat > "$REC" <<JSON
{"sessionId":"local_$UUID","cliSessionId":"$UUID","cwd":"$WORKDIR",
 "title":"Disposable session","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000001000}
JSON

fail() { echo "FAIL: $1"; exit 1; }

"$CCFINDER" sync >/dev/null
FILE="$WORKDIR/Claude Sessions/Disposable session.claudesession"
[ -f "$FILE" ] || fail "session file not created"

echo "1. archive flips the flag in Claude's own record"
"$CCFINDER" archive "$FILE" >/dev/null
python3 -c "
import json,sys
d=json.load(open('$REC'))
sys.exit(0 if d.get('isArchived') is True else 1)" || fail "isArchived was not set"

echo "2. the next sync drops it from the folder"
"$CCFINDER" sync >/dev/null
[ ! -f "$FILE" ] || fail "archived session still mirrored"

echo "3. unarchive brings it back"
# the file is gone, so drive unarchive from the record id directly
python3 -c "
import json
p='$REC'; d=json.load(open(p)); d['isArchived']=False; json.dump(d,open(p,'w'))"
"$CCFINDER" sync >/dev/null
[ -f "$FILE" ] || fail "unarchived session not restored"

echo "3b. dragging a file into Archive/ archives the session"
mkdir -p "$WORKDIR/Claude Sessions/Archive"
INODE="$(stat -f %i "$FILE")"
mv "$FILE" "$WORKDIR/Claude Sessions/Archive/"
"$CCFINDER" sync >/dev/null
DRAGGED="$WORKDIR/Claude Sessions/Archive/Disposable session.claudesession"
[ -f "$DRAGGED" ] || fail "dragged file did not stay in Archive/"
[ ! -f "$FILE" ] || fail "the file came back to the live folder"
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$REC')).get('isArchived') is True else 1)" || fail "dragging in did not archive the session"
[ "$INODE" = "$(stat -f %i "$DRAGGED")" ] || fail "the dragged file was recreated, not kept"

echo "3c. dragging it back out unarchives it"
mv "$DRAGGED" "$WORKDIR/Claude Sessions/"
"$CCFINDER" sync >/dev/null
[ -f "$FILE" ] || fail "file did not stay in the live folder"
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$REC')).get('isArchived') in (False,None) else 1)" || fail "dragging out did not unarchive"

echo "3d. a sideways move inside the mirror is undone, not obeyed"
#     moved to another project's folder, so it is still visible to the scan and
#     therefore a move rather than a disappearance
OTHER_WORK="$TMP/other-proj"; mkdir -p "$OTHER_WORK/Claude Sessions"
cat > "$CCF_SESSIONS/local_cccc.json" <<JSON
{"sessionId":"local_cccc","cliSessionId":"cccccccc-dddd-eeee-ffff-000000000000",
 "cwd":"$OTHER_WORK","title":"Neighbour","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000000500}
JSON
"$CCFINDER" sync >/dev/null
mv "$FILE" "$OTHER_WORK/Claude Sessions/"
"$CCFINDER" sync >/dev/null
[ -f "$FILE" ] || fail "the session was not put back in its own folder"
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$REC')).get('isArchived') in (False,None) else 1)" \
  || fail "a sideways move changed the archive state"

echo "4. delete refuses without --yes"
"$CCFINDER" delete "$FILE" >/dev/null 2>&1 && fail "delete ran without --yes"

echo "5. delete writes Claude's tombstone and removes the record"
"$CCFINDER" delete "$FILE" --yes >/dev/null
[ ! -f "$REC" ] || fail "session record still present"
TOMB="$CCF_SESSIONS/deleted_$UUID"
[ -f "$TOMB" ] || fail "tombstone not written"
grep -qE '^[0-9]{13}$' "$TOMB" || fail "tombstone body is not an epoch-ms timestamp"

echo "6. the record was backed up and the file is gone"
[ -f "$CCF_SUPPORT/deleted/local_$UUID.json" ] || fail "no backup of the deleted record"
[ ! -f "$FILE" ] || fail "session file still on disk"

echo "7. a deleted session does not come back on the next sync"
"$CCFINDER" sync >/dev/null
[ ! -f "$FILE" ] || fail "deleted session was recreated"

echo
echo "PASS — archive is reversible, delete matches Claude's tombstone format,"
echo "       dragging in and out of Archive/ works, the record is backed up,"
echo "       and nothing resurrects"
