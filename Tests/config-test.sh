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

echo "2. archive hide removes the Archive folder"
"$CCFINDER" config archive hide >/dev/null
[ ! -f "$WORKDIR/Claude Sessions/Archive/Old one.claudesession" ] || fail "archived session still mirrored"
[ -f "$WORKDIR/Claude Sessions/Live one.claudesession" ] || fail "live session disappeared too"

echo "3. archive show brings it back"
"$CCFINDER" config archive show >/dev/null
[ -f "$WORKDIR/Claude Sessions/Archive/Old one.claudesession" ] || fail "archived session did not come back"

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

echo
echo "PASS — both settings take effect immediately and survive a restart"
