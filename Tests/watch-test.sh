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

echo
echo "PASS — watcher reacts to both creation and retitling"
