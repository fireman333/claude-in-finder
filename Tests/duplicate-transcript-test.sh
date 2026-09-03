#!/bin/bash
# Two Claude Desktop sessions can point at the same CLI transcript. They then
# carry the same title and want the same file name — and the loser of that clash
# used to be given a suffix taken from the CLI id, which is the very thing the
# two of them share. Both were handed the same "unique" name.
#
# It stayed hidden until the older session was used again and the clash changed
# hands. Then each pass moved one file on top of the other, the survivor
# disagreed with the index about whose it was, that read as a rename made in
# Finder, and the suffix was written back into Claude as the session's title.
# The two names traded places every few seconds from then on, re-reading every
# transcript on disk each time round.
#
# Also covers the other half of that cost: a pass must not read a transcript
# whose bytes and session fields have not changed since the last one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# --show-bin-path only prints the path, it does not build. Without this the
# whole suite silently exercises whatever binary was last compiled.
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
SHARED="fefcff0f-ab39-420b-bcce-7cffe354ac2a"
TRANSCRIPT="$CCF_PROJECTS/slug/$SHARED.jsonl"
A="43239c41-e1cb-474b-bf33-d4b37bfd7e72"
B="fefcff0f-ab39-420b-bcce-7cffe354ac2a"

fail() { echo "FAIL: $1"; exit 1; }

write_session() {  # write_session <uuid> <title> <lastActivity>
  cat > "$CCF_SESSIONS/local_$1.json" <<JSON
{"sessionId":"local_$1","cliSessionId":"$SHARED","cwd":"$WORKDIR",
 "title":"$2","titleSource":"auto","isArchived":false,
 "createdAt":1780000000000,"lastActivityAt":$3,"model":"claude-opus-5"}
JSON
}
title_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$CCF_SESSIONS/local_$1.json"; }
msg() { printf '{"type":"%s","message":{"role":"%s","content":"%s"}}\n' "$1" "$1" "$2"; }
files() { find "$DIR" -maxdepth 1 -name '*.claudesession' ! -name '+ New Session*' | wc -l | tr -d ' '; }

{ msg user "hello"; msg assistant "hi there"; } > "$TRANSCRIPT"
write_session "$A" "Shared transcript" 1788000000000
write_session "$B" "Shared transcript" 1787000000000   # A is the newer one

echo "1. both sessions get a file, under names that actually differ"
"$CCFINDER" sync >/dev/null 2>&1
[ "$(files)" = "2" ] || fail "expected 2 mirrored files, found $(files)"
for id in "$A" "$B"; do
  grep -lq "local_$id" "$DIR"/*.claudesession 2>/dev/null || fail "no file carries local_$id"
done

echo "2. using the older session hands it the unsuffixed name — without a fight"
write_session "$B" "Shared transcript" 1789000000000   # B is now the newer one
"$CCFINDER" sync >/dev/null 2>&1
[ "$(files)" = "2" ] || fail "a file was lost when the clash changed hands: $(files) left"
for id in "$A" "$B"; do
  grep -lq "local_$id" "$DIR"/*.claudesession 2>/dev/null \
    || fail "local_$id's file was overwritten by the other session's"
done

echo "3. no pass ever writes a suffix back into Claude as the title"
for pass in 3 4 5; do
  OUT="$("$CCFINDER" sync 2>"$TMP/err.$pass")"
  ! grep -q "renamed in Finder" "$TMP/err.$pass" \
    || fail "pass $pass mistook our own suffix for a rename in Finder"
  [ "$(title_of "$A")" = "Shared transcript" ] || fail "pass $pass rewrote A's title to '$(title_of "$A")'"
  [ "$(title_of "$B")" = "Shared transcript" ] || fail "pass $pass rewrote B's title to '$(title_of "$B")'"
  echo "$OUT" | grep -q "^created 0, updated 0, renamed 0, removed 0$" \
    || fail "pass $pass was not a no-op: $OUT"
done

echo "4. a rename made in Finder is still obeyed"
CLEAN="$DIR/Shared transcript.claudesession"
[ -f "$CLEAN" ] || fail "expected the newer session to hold the unsuffixed name"
mv "$CLEAN" "$DIR/Renamed by hand.claudesession"
"$CCFINDER" sync >/dev/null 2>&1
[ "$(title_of "$B")" = "Renamed by hand" ] || fail "a real rename was ignored; title is '$(title_of "$B")'"

echo "5. a file parked by a pass that died mid-swap is put back, not lost"
SURVIVOR="$(find "$DIR" -maxdepth 1 -name '*.claudesession' ! -name '+ New Session*' | head -1)"
mv "$SURVIVOR" "$DIR/.ccf-moving-stray.claudesession"
"$CCFINDER" sync >/dev/null 2>&1
[ -z "$(find "$DIR" -maxdepth 1 -name '.ccf-moving-*')" ] || fail "the parked file was left behind"
[ "$(files)" = "2" ] || fail "a parked file was pruned instead of collected: $(files) left"
for id in "$A" "$B"; do
  grep -lq "local_$id" "$DIR"/*.claudesession 2>/dev/null || fail "local_$id was lost in recovery"
done
[ "$(title_of "$A")" = "Shared transcript" ] || fail "recovery rewrote A's title to '$(title_of "$A")'"

echo "6. an unchanged transcript is not read again"
rm -f "$CCF_SESSIONS/local_$B.json"
write_session "$A" "Solo" 1788000000000
"$CCFINDER" sync >/dev/null 2>&1
SOLO="$DIR/Solo.claudesession"
[ -f "$SOLO" ] || fail "expected $SOLO"
BEFORE="$(stat -f %m "$SOLO")"
chmod -r "$TRANSCRIPT"        # a pass that still parses it would render an empty preview
OUT="$("$CCFINDER" sync 2>/dev/null)"
chmod +r "$TRANSCRIPT"
echo "$OUT" | grep -q "updated 0" || fail "an unchanged transcript was re-rendered: $OUT"
grep -q "hi there" "$SOLO" || fail "the preview lost its content"
[ "$(stat -f %m "$SOLO")" = "$BEFORE" ] || fail "the file was rewritten with nothing to change"

echo "7. a changed transcript is picked up"
msg assistant "a new turn" >> "$TRANSCRIPT"
"$CCFINDER" sync >/dev/null 2>&1
grep -q "a new turn" "$SOLO" || fail "an appended turn never reached the preview"

echo
echo "PASS — sessions sharing one transcript keep distinct files and settle,"
echo "       Claude's titles are left alone, and unchanged transcripts are not re-read"
