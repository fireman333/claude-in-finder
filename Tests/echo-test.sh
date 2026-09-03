#!/bin/bash
# A pass stamps every file it mirrors with the conversation's dates, and those
# writes land in folders the watcher is watching. The event comes back and buys a
# second pass that can only ever find nothing: one change, two passes, all day.
#
# This checks that the second pass is gone, that it was deferred rather than
# thrown away, and — the thing that makes the shortcut safe — that a file moved
# by hand still wakes the watcher at once, however familiar its path looks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build -c release --package-path "$ROOT" >/dev/null
CCFINDER="$(swift build -c release --show-bin-path --package-path "$ROOT")/ccfinder"
TMP="$(mktemp -d)"

export CCF_SESSIONS="$TMP/sessions/acct/org"
export CCF_MIRROR="$TMP/central"
export CCF_INDEX="$TMP/index.json"
export CCF_SUPPORT="$TMP/support"
export CCF_TRASH="$TMP/trash"
mkdir -p "$CCF_SESSIONS" "$TMP/trash"
WORKDIR="$TMP/watched-project"; mkdir -p "$WORKDIR"
DIR="$WORKDIR/Claude Sessions"
LOG="$TMP/watch.log"

fail() { echo "FAIL: $1"; echo "--- watcher log ---"; cat "$LOG"; exit 1; }
passes() { grep -c '\] +' "$LOG" 2>/dev/null || true; }

write_session() {   # write_session <title> <lastActivity>
  cat > "$CCF_SESSIONS/local_cccc.json" <<JSON
{"sessionId":"local_cccc","cliSessionId":"11111111-2222-3333-4444-555555555555",
 "cwd":"$WORKDIR","title":"$1","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":$2}
JSON
}

wait_for() { local t="$1" n=0; while [ ! -e "$t" ]; do sleep 0.5; n=$((n+1)); [ "$n" -gt 40 ] && return 1; done; return 0; }

"$CCFINDER" watch -v > "$LOG" 2>&1 &
WATCH_PID=$!
disown %1 2>/dev/null || true
trap 'kill $WATCH_PID 2>/dev/null || true; rm -rf "$TMP"' EXIT
sleep 2

echo "1. a session appears and is mirrored"
write_session "Echo subject" 1780000001000
wait_for "$DIR/Echo subject.claudesession" || fail "the watcher never created the file"
sleep 4

echo "2. one conversation update costs one pass, not two"
BEFORE="$(passes)"
write_session "Echo subject" 1780000900000     # same title, later activity
sleep 7
AFTER="$(passes)"
SPENT=$((AFTER - BEFORE))
[ "$SPENT" -ge 1 ] || fail "the change was not noticed at all"
[ "$SPENT" -le 1 ] || fail "one change cost $SPENT passes; the stamp is still echoing"
echo "   $SPENT pass"

echo "3. the skipped pass was deferred, not dropped"
sleep 22
LATER="$(passes)"
[ "$LATER" -gt "$AFTER" ] || fail "nothing looked again after the echo was skipped"
echo "   looked again $((LATER - AFTER)) time(s)"

echo "4. a file moved by hand still wakes it at once"
#    A rename is structural, so it is never mistaken for our own writing, even
#    though the mirror wrote that very path moments earlier.
mkdir -p "$DIR/Archive"
mv "$DIR/Echo subject.claudesession" "$DIR/Archive/"
n=0
until python3 -c "
import json,sys
sys.exit(0 if json.load(open('$CCF_SESSIONS/local_cccc.json')).get('isArchived') is True else 1)" 2>/dev/null; do
  sleep 0.5; n=$((n+1))
  [ "$n" -gt 16 ] && fail "a drag into Archive/ was mistaken for our own echo"
done
echo "   archived in $(echo "scale=1; $n/2" | bc)s"

echo
echo "PASS — one change costs one pass, the skipped one is still checked later,"
echo "       and a move made by hand is never mistaken for our own writing"
