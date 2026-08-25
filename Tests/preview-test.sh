#!/bin/bash
# Verifies what the mirrored file itself carries: the conversation's own dates,
# the deep link it stands for, and an honest preview when it is too long to show.
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
export CCF_PROJECTS="$TMP/projects"
mkdir -p "$CCF_SESSIONS" "$CCF_TRASH" "$CCF_PROJECTS/proj"
WORKDIR="$TMP/proj"; mkdir -p "$WORKDIR"

UUID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CREATED_MS=1740000000000     # 2025-02-19 21:20 UTC
ACTIVITY_MS=1750000000000    # 2025-06-15 15:06 UTC

cat > "$CCF_SESSIONS/local_$UUID.json" <<JSON
{"sessionId":"local_$UUID","cliSessionId":"$UUID","cwd":"$WORKDIR",
 "title":"Long one","titleSource":"user","isArchived":false,
 "createdAt":$CREATED_MS,"lastActivityAt":$ACTIVITY_MS}
JSON

fail() { echo "FAIL: $1"; exit 1; }
FILE="$WORKDIR/Claude Sessions/Long one.claudesession"

echo "1. the file carries the conversation's dates, not the sync's"
"$CCFINDER" sync >/dev/null
[ -f "$FILE" ] || fail "setup: session not mirrored"
MTIME="$(stat -f %m "$FILE")"
BTIME="$(stat -f %B "$FILE")"
[ "$MTIME" = "$((ACTIVITY_MS / 1000))" ] || fail "modification date is $MTIME, wanted $((ACTIVITY_MS / 1000))"
[ "$BTIME" = "$((CREATED_MS / 1000))" ] || fail "creation date is $BTIME, wanted $((CREATED_MS / 1000))"

echo "2. a later sync leaves them alone"
#    stamping on every pass would fire an FSEvent, wake the watcher, and loop
"$CCFINDER" sync >/dev/null
[ "$(stat -f %m "$FILE")" = "$MTIME" ] || fail "the stamp was rewritten on an unchanged pass"

echo "3. a new activity time moves the file's date with it"
python3 - <<PY
import json
p = "$CCF_SESSIONS/local_$UUID.json"
d = json.load(open(p))
d["lastActivityAt"] = $ACTIVITY_MS + 86400000
json.dump(d, open(p, "w"))
PY
"$CCFINDER" sync >/dev/null
[ "$(stat -f %m "$FILE")" = "$(( ACTIVITY_MS / 1000 + 86400 ))" ] || fail "the date did not follow the session"

echo "4. a short conversation says nothing about truncation"
python3 - <<PY
import json
with open("$CCF_PROJECTS/proj/$UUID.jsonl", "w") as f:
    for i in range(4):
        for role in ("user", "assistant"):
            f.write(json.dumps({"type": role, "message":
                {"content": [{"type": "text", "text": f"{role} line {i}"}]}}) + "\n")
PY
"$CCFINDER" sync >/dev/null
grep -q "user line 0" "$FILE" || fail "the transcript was not rendered at all"
grep -q "not shown" "$FILE" && fail "a short conversation should carry no truncation notice" || true

echo "5. a long one says how many messages it is not showing"
python3 - <<PY
import json
with open("$CCF_PROJECTS/proj/$UUID.jsonl", "w") as f:
    for i in range(160):          # 160 pairs = 320 messages, 20 over the 300 kept
        for role in ("user", "assistant"):
            f.write(json.dumps({"type": role, "message":
                {"content": [{"type": "text", "text": f"{role} line {i}"}]}}) + "\n")
PY
"$CCFINDER" sync >/dev/null
grep -q "20 earlier messages not shown" "$FILE" \
  || fail "the preview does not say how much it dropped"
grep -q "user line 159" "$FILE" || fail "the tail — the part worth keeping — is missing"
grep -q "user line 0" "$FILE" && fail "the head should have been dropped" || true

echo "6. ccfinder link prints the link a file stands for"
"$CCFINDER" link "$FILE" | grep -q "^claude://resume?session=$UUID$" \
  || fail "the resume link is wrong"
NEW="$WORKDIR/Claude Sessions/+ New Session.claudesession"
[ -f "$NEW" ] && { "$CCFINDER" link "$NEW" | grep -q "^claude://code/new?folder=" \
  || fail "the + New Session link is wrong"; }
"$CCFINDER" link "$WORKDIR" >/dev/null 2>&1 && fail "a folder is not a session file" || true

echo
echo "PASS — files carry the conversation's own dates, the preview admits what it"
echo "       leaves out, and every file can hand back its claude:// link"
