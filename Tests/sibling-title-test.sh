#!/bin/bash
# A scheduled task starts a new session every day under the same title. The new
# one is the most recent, so it takes the clean name — the name the previous
# day's session is still sitting under. Having no file of its own to move, the
# newcomer skipped the step that sets an occupant aside and wrote its page
# straight over the old session's file.
#
# From then on there was one file for two sessions. The old one, its own file
# gone, followed the index to the newcomer's and carried it off under its own
# suffix; the newcomer found its file under that suffix, took it for a rename in
# Finder and wrote the suffix into Claude as its title. Each pass moved the one
# file back again. The agent ran a full pass every two and a half seconds, for
# days, and kept rewriting the titles of the sessions caught in it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build -c release --package-path "$ROOT" >/dev/null
CCFINDER="$(swift build -c release --show-bin-path --package-path "$ROOT")/ccfinder"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CCF_SESSIONS="$TMP/sessions/acct/org"
export CCF_PROJECTS="$TMP/projects"
export CCF_MIRROR="$TMP/central"
export CCF_INDEX="$TMP/index.json"
export CCF_SUPPORT="$TMP/support"
export CCF_TRASH="$TMP/trash"
mkdir -p "$CCF_SESSIONS" "$CCF_PROJECTS/slug" "$TMP/trash"

WORKDIR="$TMP/demo-project"
mkdir -p "$WORKDIR"
DIR="$WORKDIR/Claude Sessions"
A="d040eb48-19b2-44b2-9c5c-809fe11b02c1"   # yesterday's run
B="abb7bc99-d46c-440b-8916-3dd1d00863e1"   # today's run
C="d3f9b1e9-c948-4dbc-9965-3a1e7c105b13"   # tomorrow's run

fail() { echo "FAIL: $1"; exit 1; }

write_session() {  # write_session <uuid> <title> <lastActivity>
  cat > "$CCF_SESSIONS/local_$1.json" <<JSON
{"sessionId":"local_$1","cliSessionId":"cli-$1","cwd":"$WORKDIR",
 "title":"$2","titleSource":"auto","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":$3,"model":"claude-opus-5"}
JSON
  printf '{"type":"user","message":{"role":"user","content":"run %s"}}\n' "$1" \
    > "$CCF_PROJECTS/slug/cli-$1.jsonl"
}
title_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$CCF_SESSIONS/local_$1.json"; }
file_of() { grep -l "local_$1" "$DIR"/*.claudesession 2>/dev/null | head -1; }
files() { find "$DIR" -maxdepth 1 -name '*.claudesession' ! -name '+ New Session*' | wc -l | tr -d ' '; }
settled() {  # settled <pass label>
  OUT="$("$CCFINDER" sync 2>"$TMP/err")"
  ! grep -q "renamed in Finder" "$TMP/err" || fail "$1: mistook our own naming for a rename in Finder"
  echo "$OUT" | grep -q "^created 0, updated 0, renamed 0, removed 0$" || fail "$1 was not a no-op: $OUT"
}

echo "1. a new session under an old one's title leaves the old one's file alone"
write_session "$A" "Daily" 1791858359771
"$CCFINDER" sync >/dev/null 2>&1
write_session "$B" "Daily" 1792058263981
"$CCFINDER" sync >/dev/null 2>"$TMP/err"
! grep -q "renamed in Finder" "$TMP/err" || fail "the arrival was read as a rename in Finder"
[ "$(files)" = "2" ] || fail "expected 2 files after the arrival, found $(files)"
[ -n "$(file_of "$A")" ] || fail "the older session's file was overwritten by the newcomer's"
[ "$(basename "$(file_of "$B")")" = "Daily.claudesession" ] || fail "the newcomer did not take the clean name"

echo "2. and it settles: nothing moves, no title is touched"
for pass in 1 2 3; do settled "pass $pass"; done
[ "$(title_of "$A")" = "Daily" ] || fail "A's title became '$(title_of "$A")'"
[ "$(title_of "$B")" = "Daily" ] || fail "B's title became '$(title_of "$B")'"

echo "3. a third run arriving does the same"
write_session "$C" "Daily" 1792123286181
"$CCFINDER" sync >/dev/null 2>&1
[ "$(files)" = "3" ] || fail "expected 3 files, found $(files)"
for id in "$A" "$B" "$C"; do [ -n "$(file_of "$id")" ] || fail "local_$id lost its file"; done
for pass in 1 2; do settled "pass $pass after the third run"; done

echo "4. a mirror an earlier build left with one file for two sessions heals"
# What the bug left behind: B's title carries A's suffix, A has no file, and the
# index still sends A to the path where B's file now stands.
write_session "$B" "Daily · d040eb" 1792058263981
"$CCFINDER" sync >/dev/null 2>&1
B_FILE="$(file_of "$B")"
rm -f "$(file_of "$A")"
mv "$B_FILE" "$DIR/Daily · d040eb-2.claudesession"
python3 - "$CCF_INDEX" "$A" "$B" "$DIR" <<'EOF'
import json, sys
path, a, b, d = sys.argv[1:]
idx = json.load(open(path))
idx["entries"]["local_" + a]["path"] = d + "/Daily · d040eb-2.claudesession"
idx["entries"]["local_" + b]["path"] = d + "/Daily · d040eb.claudesession"
json.dump(idx, open(path, "w"))
EOF
"$CCFINDER" sync >/dev/null 2>&1
[ "$(files)" = "3" ] || fail "expected 3 files after healing, found $(files)"
for id in "$A" "$B" "$C"; do [ -n "$(file_of "$id")" ] || fail "local_$id has no file after healing"; done
for pass in 1 2 3; do settled "healed pass $pass"; done
[ "$(title_of "$A")" = "Daily" ] || fail "healing rewrote A's title to '$(title_of "$A")'"

echo "5. a file reaching a session under a sibling's suffix is not a rename"
# However it got there. Writing the sibling's suffix into Claude as this
# session's title is what named sessions after one another.
write_session "$B" "Daily" 1792058263981
"$CCFINDER" sync >/dev/null 2>&1
A_NAME="$(basename "$(file_of "$A")")"
B_NAME="$(basename "$(file_of "$B")")"
mv "$DIR/$B_NAME" "$TMP/b.claudesession"
mv "$DIR/$A_NAME" "$DIR/$B_NAME"
mv "$TMP/b.claudesession" "$DIR/$A_NAME"
"$CCFINDER" sync >/dev/null 2>"$TMP/err"
[ "$(title_of "$B")" = "Daily" ] || fail "a sibling's suffix became B's title: '$(title_of "$B")'"
[ "$(title_of "$A")" = "Daily" ] || fail "A's title became '$(title_of "$A")'"
for id in "$A" "$B" "$C"; do [ -n "$(file_of "$id")" ] || fail "local_$id has no file"; done
settled "after the swap"

echo "6. a real rename to some other name is still obeyed"
mv "$(file_of "$A")" "$DIR/Yesterday's run.claudesession"
"$CCFINDER" sync >/dev/null 2>&1
[ "$(title_of "$A")" = "Yesterday's run" ] || fail "a real rename was ignored; title is '$(title_of "$A")'"

echo "7. upgrading, a session whose file an older build overwrote is re-mirrored, not archived"
archived_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["isArchived"])' "$CCF_SESSIONS/local_$1.json"; }
# As the old build left it: A's file gone, B's file standing at A's name and
# about to move back to its own, and the index still sending A there.
write_session "$A" "Daily" 1791858359771
"$CCFINDER" sync >/dev/null 2>&1
A_PATH="$(file_of "$A")"
B_PATH="$(file_of "$B")"
rm -f "$A_PATH"
mv "$B_PATH" "$A_PATH"
python3 - "$CCF_INDEX" "$A" "$B" "$A_PATH" "$B_PATH" <<'EOF'
import json, sys
path, a, b, a_path, b_path = sys.argv[1:]
idx = json.load(open(path)); idx["version"] = 2
idx["entries"]["local_" + a]["path"] = a_path
idx["entries"]["local_" + b]["path"] = b_path
json.dump(idx, open(path, "w"))
EOF
"$CCFINDER" sync >/dev/null 2>&1
[ "$(title_of "$B")" = "Daily" ] || fail "B's title became '$(title_of "$B")'"
[ "$(archived_of "$A")" = "False" ] || fail "the upgrade archived a session whose file the old build lost"
[ -n "$(file_of "$A")" ] || fail "the session was not mirrored afresh"
for pass in 1 2; do settled "after the upgrade, pass $pass"; done

echo "8. after that one upgrade, deleting a file in Finder archives as it always did"
rm -f "$(file_of "$A")"
"$CCFINDER" sync >/dev/null 2>&1
[ "$(archived_of "$A")" = "True" ] || fail "a file deleted in Finder no longer archives its session"

echo "9. titles differing only in case are one name on disk, and settle"
rm -f "$CCF_SESSIONS"/local_*.json "$CCF_INDEX"
rm -rf "$DIR"
write_session "$A" "Daily" 1791858359771
"$CCFINDER" sync >/dev/null 2>&1
write_session "$B" "daily" 1792058263981
"$CCFINDER" sync >/dev/null 2>&1
[ "$(files)" = "2" ] || fail "expected 2 files for names differing in case, found $(files)"
for id in "$A" "$B"; do [ -n "$(file_of "$id")" ] || fail "local_$id has no visible file"; done
[ -z "$(find "$DIR" -maxdepth 1 -name '.ccf-moving-*')" ] || fail "a file was left parked"
for pass in 1 2; do settled "case clash, pass $pass"; done
# Lowercasing alone keeps a final sigma apart from a medial one; the disk does not.
rm -f "$CCF_SESSIONS"/local_*.json "$CCF_INDEX"
rm -rf "$DIR"
write_session "$A" "οδοσ" 1791858359771
"$CCFINDER" sync >/dev/null 2>&1
write_session "$B" "οδος" 1792058263981
"$CCFINDER" sync >/dev/null 2>&1
for id in "$A" "$B"; do [ -n "$(file_of "$id")" ] || fail "sigma clash: local_$id has no visible file"; done
[ -z "$(find "$DIR" -maxdepth 1 -name '.ccf-moving-*')" ] || fail "sigma clash: a file was left parked"
for pass in 1 2; do settled "sigma clash, pass $pass"; done

echo "10. with --no-prune, a file whose session is gone does not keep a new one out"
rm -f "$CCF_SESSIONS"/local_*.json "$CCF_INDEX"
rm -rf "$DIR"
write_session "$A" "Daily" 1791858359771
"$CCFINDER" sync >/dev/null 2>&1
rm -f "$CCF_SESSIONS/local_$A.json"
write_session "$B" "Daily" 1792058263981
"$CCFINDER" sync --no-prune >/dev/null 2>&1
grep -lq "local_$A" "$DIR"/*.claudesession || fail "the gone session's file was deleted despite --no-prune"
[ -n "$(file_of "$B")" ] || fail "the new session was never mirrored"
OUT="$("$CCFINDER" sync --no-prune 2>/dev/null)"
echo "$OUT" | grep -q "^created 0, updated 0, renamed 0, removed 0$" || fail "--no-prune did not settle: $OUT"

echo
echo "PASS — a new session under a used title never overwrites the old one's file,"
echo "       a broken mirror heals in one pass, and sibling suffixes stay out of titles"
