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

echo "4. archiving one, then bringing it back, does not archive the other"
# The one left behind takes the freed-up unsuffixed name, so the returning file
# lands on top of it. Deleting the occupant is read, a second later, as the user
# throwing that session away.
archived_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["isArchived"])' "$CCF_SESSIONS/local_$1.json"; }
B_FILE="$(grep -l "local_$B" "$DIR"/*.claudesession | head -1)"
"$CCFINDER" archive "$B_FILE" >/dev/null 2>&1
"$CCFINDER" sync >/dev/null 2>&1
[ -f "$DIR/Shared transcript.claudesession" ] || fail "the remaining session did not take the freed name"
ARCHIVED_FILE="$(find "$DIR/Archive" -name '*.claudesession' | head -1)"
[ -n "$ARCHIVED_FILE" ] || fail "nothing landed in Archive/"
"$CCFINDER" unarchive "$ARCHIVED_FILE" >/dev/null 2>&1
"$CCFINDER" sync >/dev/null 2>&1
"$CCFINDER" sync >/dev/null 2>&1
[ "$(archived_of "$A")" = "False" ] || fail "bringing B back archived A"
[ "$(archived_of "$B")" = "False" ] || fail "B did not come back"
[ "$(files)" = "2" ] || fail "a file was lost across the archive round trip: $(files) left"
for id in "$A" "$B"; do
  grep -lq "local_$id" "$DIR"/*.claudesession 2>/dev/null || fail "local_$id lost in the round trip"
done
echo "5. a rename made in Finder is still obeyed"
CLEAN="$DIR/Shared transcript.claudesession"
[ -f "$CLEAN" ] || fail "expected the newer session to hold the unsuffixed name"
mv "$CLEAN" "$DIR/Renamed by hand.claudesession"
"$CCFINDER" sync >/dev/null 2>&1
[ "$(title_of "$B")" = "Renamed by hand" ] || fail "a real rename was ignored; title is '$(title_of "$B")'"

echo "6. a file parked by a pass that died mid-swap is put back, not lost"
SURVIVOR="$(find "$DIR" -maxdepth 1 -name '*.claudesession' ! -name '+ New Session*' | head -1)"
mv "$SURVIVOR" "$DIR/.ccf-moving-stray.claudesession"
"$CCFINDER" sync >/dev/null 2>&1
[ -z "$(find "$DIR" -maxdepth 1 -name '.ccf-moving-*')" ] || fail "the parked file was left behind"
[ "$(files)" = "2" ] || fail "a parked file was pruned instead of collected: $(files) left"
for id in "$A" "$B"; do
  grep -lq "local_$id" "$DIR"/*.claudesession 2>/dev/null || fail "local_$id was lost in recovery"
done
[ "$(title_of "$A")" = "Shared transcript" ] || fail "recovery rewrote A's title to '$(title_of "$A")'"

echo "7. an unchanged transcript is not read again"
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

echo "8. a changed transcript is picked up"
msg assistant "a new turn" >> "$TRANSCRIPT"
"$CCFINDER" sync >/dev/null 2>&1
grep -q "a new turn" "$SOLO" || fail "an appended turn never reached the preview"

echo "9. a page is never written onto a path that could not be cleared"
# Two sessions must swap names, but every slot to set the occupant aside in is
# taken. Falling through would write one session's page over the other's file.
write_session "$A" "Contested" 1790000000000
write_session "$B" "Contested" 1791000000000
"$CCFINDER" sync >/dev/null 2>&1
write_session "$A" "Contested" 1792000000000   # A is now newer: they must trade
for n in 1 $(seq 2 50); do
  [ "$n" = 1 ] && f="$DIR/.ccf-moving-$B.claudesession" || f="$DIR/.ccf-moving-$B-$n.claudesession"
  : > "$f"
done
"$CCFINDER" sync >/dev/null 2>&1
grep -lq "local_$B" "$DIR"/*.claudesession 2>/dev/null \
  || fail "B's conversation was overwritten by A when the way could not be cleared"
grep -lq "local_$A" "$DIR"/*.claudesession 2>/dev/null || fail "A's file was lost"
[ "$(archived_of "$B")" = "False" ] || fail "B was archived after the blocked swap"
rm -f "$DIR"/.ccf-moving-*

echo "10. a rename that merely looks like our suffix is still passed to Claude"
# " · 202601" has the shape of a disambiguator — digits are hex — but it is not
# this session's, so it is a name the user typed.
rm -f "$CCF_SESSIONS/local_$B.json"
"$CCFINDER" sync >/dev/null 2>&1
SOLO2="$(grep -l "local_$A" "$DIR"/*.claudesession | head -1)"
mv "$SOLO2" "$DIR/Sprint · 202601.claudesession"
"$CCFINDER" sync >/dev/null 2>&1
[ "$(title_of "$A")" = "Sprint · 202601" ] \
  || fail "a real rename was swallowed as a disambiguator; title is '$(title_of "$A")'"

echo "11. a build that renders differently refreshes every preview once"
"$CCFINDER" sync >/dev/null 2>&1
OUT="$("$CCFINDER" sync)"
echo "$OUT" | grep -q "updated 0" || fail "not settled before the upgrade: $OUT"
# Prove the new build actually re-rendered by making the transcript unreadable:
# a pass that reuses the stored preview cannot notice, one that re-renders must.
chmod -r "$TRANSCRIPT"
OUT="$(CCF_VERSION=99.9.9 "$CCFINDER" sync 2>/dev/null)"
chmod +r "$TRANSCRIPT"
FILE="$(grep -l "local_$A" "$DIR"/*.claudesession | head -1)"
grep -q "No messages to show" "$FILE" \
  || fail "a new build served the old build's preview instead of re-rendering: $OUT"

echo "12. a transcript that was briefly unreadable is not remembered as empty"
OUT="$(CCF_VERSION=99.9.9 "$CCFINDER" sync)"
FILE="$(grep -l "local_$A" "$DIR"/*.claudesession | head -1)"
grep -q "hi there" "$FILE" || fail "the empty preview was cached and never retried: $OUT"
echo
echo "PASS — sessions sharing one transcript keep distinct files and settle,"
echo "       Claude's titles are left alone, and unchanged transcripts are not re-read"
