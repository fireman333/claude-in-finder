#!/bin/bash
# Verifies that archiving and deleting work on a multiple selection, which is what
# the Finder services hand over when several sessions are selected at once.
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
mkdir -p "$TMP/trash"
mkdir -p "$CCF_SESSIONS"
WORKDIR="$TMP/proj"; mkdir -p "$WORKDIR"
LIVE="$WORKDIR/Claude Sessions"

fail() { echo "FAIL: $1"; exit 1; }

make_session() {  # make_session <n>
  local u="0000000$1-1111-2222-3333-444444444444"
  cat > "$CCF_SESSIONS/local_$u.json" <<JSON
{"sessionId":"local_$u","cliSessionId":"$u","cwd":"$WORKDIR",
 "title":"Session $1","titleSource":"user","isArchived":false,
 "createdAt":178000000000$1,"lastActivityAt":178000000100$1}
JSON
}
for n in 1 2 3 4 5; do make_session $n; done
"$CCFINDER" sync >/dev/null
for n in 1 2 3 4 5; do
  [ -f "$LIVE/Session $n.claudesession" ] || fail "Session $n was not mirrored"
done

echo "1. archiving three at once"
"$CCFINDER" archive "$LIVE/Session 1.claudesession" \
                    "$LIVE/Session 2.claudesession" \
                    "$LIVE/Session 3.claudesession" > "$TMP/out" 2>&1
[ "$(grep -c '^archived:' "$TMP/out")" = "3" ] || { cat "$TMP/out"; fail "expected three archived lines"; }

echo "2. all three moved into Archive/ immediately, without waiting for a sync"
for n in 1 2 3; do
  [ -f "$LIVE/Archive/Session $n.claudesession" ] || fail "Session $n is not in Archive/"
  [ ! -f "$LIVE/Session $n.claudesession" ] || fail "Session $n left behind in the live folder"
done
for n in 4 5; do
  [ -f "$LIVE/Session $n.claudesession" ] || fail "Session $n should not have moved"
done

echo "3. Claude's records agree"
for n in 1 2 3; do
  python3 -c "
import json,sys
d=json.load(open('$CCF_SESSIONS/local_0000000$n-1111-2222-3333-444444444444.json'))
sys.exit(0 if d.get('isArchived') is True else 1)" || fail "record $n not archived"
done

echo "4. a sync afterwards changes nothing"
OUT="$("$CCFINDER" sync)"
echo "$OUT" | grep -q "renamed 0" || { echo "$OUT"; fail "sync moved files that were already in place"; }

echo "5. unarchiving the three together brings them back"
"$CCFINDER" unarchive "$LIVE/Archive/Session 1.claudesession" \
                      "$LIVE/Archive/Session 2.claudesession" \
                      "$LIVE/Archive/Session 3.claudesession" >/dev/null
for n in 1 2 3; do
  [ -f "$LIVE/Session $n.claudesession" ] || fail "Session $n did not come back"
done

echo "5b. the emptied Archive folder is cleaned up"
"$CCFINDER" sync >/dev/null
[ ! -d "$LIVE/Archive" ] || fail "an empty Archive folder was left behind"

echo "6. deleting two at once"
"$CCFINDER" delete "$LIVE/Session 4.claudesession" "$LIVE/Session 5.claudesession" --yes > "$TMP/del" 2>&1
[ "$(grep -c '^deleted:' "$TMP/del")" = "2" ] || { cat "$TMP/del"; fail "expected two deleted lines"; }
for n in 4 5; do
  [ ! -f "$LIVE/Session $n.claudesession" ] || fail "Session $n still on disk"
  [ -f "$CCF_SUPPORT/deleted/local_0000000$n-1111-2222-3333-444444444444.json" ] || fail "no backup for $n"
  [ -f "$CCF_SESSIONS/deleted_0000000$n-1111-2222-3333-444444444444" ] || fail "no tombstone for $n"
done

echo "7. the survivors are untouched and do not resurrect the deleted ones"
"$CCFINDER" sync >/dev/null
for n in 1 2 3; do [ -f "$LIVE/Session $n.claudesession" ] || fail "Session $n vanished"; done
for n in 4 5; do [ ! -f "$LIVE/Session $n.claudesession" ] || fail "Session $n came back"; done

echo "8. a mixed selection reports the bad file and still handles the good ones"
set +e
"$CCFINDER" archive "$LIVE/Session 1.claudesession" "$LIVE/+ New Session.claudesession" > "$TMP/mix" 2>&1
set -e
grep -q "^archived:" "$TMP/mix" || { cat "$TMP/mix"; fail "the valid session was not archived"; }
grep -q "not a session file" "$TMP/mix" || { cat "$TMP/mix"; fail "the invalid file was not reported"; }

echo
echo "PASS — batches archive, unarchive and delete correctly, move immediately,"
echo "       and a mixed selection is reported rather than silently dropped"
