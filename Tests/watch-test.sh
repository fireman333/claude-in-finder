#!/bin/bash
# Verifies that `ccfinder watch` reacts to a session appearing or being retitled
# without needing a restart — i.e. that the FSEvents wiring actually fires.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCFINDER="$(swift build -c release --show-bin-path --package-path "$ROOT")/ccfinder"
TMP="$(mktemp -d)"

export CCF_SESSIONS="$TMP/sessions/acct/org"
export CCF_MIRROR="$TMP/central"
export CCF_INDEX="$TMP/index.json"
export CCF_TRASH="$TMP/trash"
mkdir -p "$TMP/trash"
export CCF_SUPPORT="$TMP/support"
mkdir -p "$CCF_SESSIONS"

WORKDIR="$TMP/watched-project"
mkdir -p "$WORKDIR"

"$CCFINDER" watch > "$TMP/watch.log" 2>&1 &
WATCH_PID=$!
disown %1 2>/dev/null || true   # keep bash from printing "Terminated" on cleanup
trap 'kill $WATCH_PID 2>/dev/null || true; rm -rf "$TMP"' EXIT
sleep 1.5

write_session() {
  cat > "$CCF_SESSIONS/local_bbbb.json" <<JSON
{"sessionId":"local_bbbb","cliSessionId":"99999999-8888-7777-6666-555555555555",
 "cwd":"$WORKDIR","title":"$1","titleSource":"user","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":1780000001000}
JSON
}

wait_for() {  # wait_for <path> <seconds>
  local target="$1" limit="$2" waited=0
  while [ ! -e "$target" ]; do
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -gt $((limit * 2)) ] && return 1
  done
  return 0
}

echo "1. a session appears while the watcher is running"
write_session "Watched session"
if wait_for "$WORKDIR/Claude Sessions/Watched session.claudesession" 10; then
  echo "   picked up automatically"
else
  echo "FAIL: watcher never created the file"; cat "$TMP/watch.log"; exit 1
fi

echo "2. the session is retitled while the watcher is running"
write_session "Retitled live"
if wait_for "$WORKDIR/Claude Sessions/Retitled live.claudesession" 10; then
  echo "   filename followed the new title"
else
  echo "FAIL: watcher did not follow the rename"; cat "$TMP/watch.log"; exit 1
fi
[ ! -f "$WORKDIR/Claude Sessions/Watched session.claudesession" ] \
  || { echo "FAIL: old filename left behind"; exit 1; }

echo "3. dragging a file into Archive/ is picked up while running"
mkdir -p "$WORKDIR/Claude Sessions/Archive"
mv "$WORKDIR/Claude Sessions/Retitled live.claudesession" "$WORKDIR/Claude Sessions/Archive/"
waited=0
until python3 -c "
import json,sys
sys.exit(0 if json.load(open('$CCF_SESSIONS/local_bbbb.json')).get('isArchived') is True else 1)" 2>/dev/null; do
  sleep 0.5; waited=$((waited + 1))
  if [ "$waited" -gt 20 ]; then
    echo "FAIL: watcher did not notice the drag"; cat "$TMP/watch.log"; exit 1
  fi
done
echo "   the session was archived without a restart"
mv "$WORKDIR/Claude Sessions/Archive/Retitled live.claudesession" "$WORKDIR/Claude Sessions/"
until python3 -c "
import json,sys
sys.exit(0 if json.load(open('$CCF_SESSIONS/local_bbbb.json')).get('isArchived') is False else 1)" 2>/dev/null; do sleep 0.5; done

echo "4. a settings change is honoured by the running watcher"
#     the watcher used to capture its settings at startup, so it kept syncing to
#     the old layout and undid the change a few seconds later
"$CCFINDER" config layout central >/dev/null
CENTRAL="$CCF_MIRROR/watched-project/Retitled live.claudesession"
if wait_for "$CENTRAL" 10; then
  echo "   moved to the central mirror"
else
  echo "FAIL: switching layout did not move the file"; cat "$TMP/watch.log"; exit 1
fi

echo "5. and it stays there — the watcher does not put it back"
sleep 8
[ -f "$CENTRAL" ] || { echo "FAIL: the watcher undid the settings change"; cat "$TMP/watch.log"; exit 1; }
[ ! -f "$WORKDIR/Claude Sessions/Retitled live.claudesession" ] \
  || { echo "FAIL: the file reappeared in the working folder"; exit 1; }

echo "6. switching back moves it home again"
"$CCFINDER" config layout workdir >/dev/null
if wait_for "$WORKDIR/Claude Sessions/Retitled live.claudesession" 10; then
  echo "   back in the working folder"
else
  echo "FAIL: switching back did not move the file"; exit 1
fi

echo
echo "PASS — watcher reacts to creation, retitling, drag-to-archive,"
echo "       and to settings changed while it is running"
