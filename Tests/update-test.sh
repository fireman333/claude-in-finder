#!/bin/bash
# Verifies the update check: version comparison, the daily window, the setting,
# and that a failed check never passes itself off as "up to date".
#
# CCF_UPDATE_API points at a fixture file, so nothing here touches the network.
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
export CCF_UPDATE_API="$TMP/latest.json"
mkdir -p "$CCF_SESSIONS" "$CCF_TRASH"

STATE="$CCF_SUPPORT/update.json"
fail() { echo "FAIL: $1"; exit 1; }

release() {  # release <tag>
  cat > "$TMP/latest.json" <<JSON
{"tag_name":"$1","name":"Claude in Finder $1",
 "html_url":"https://github.com/fireman333/claude-in-finder/releases/tag/$1"}
JSON
}

echo "1. a newer tag is reported, with the page to go to"
release v0.11.0
CCF_VERSION=0.10.0 "$CCFINDER" update > "$TMP/out" || fail "the check exited non-zero"
grep -q "update available: 0.11.0" "$TMP/out" || fail "a newer release was not reported"
grep -q "releases/tag/v0.11.0" "$TMP/out" || fail "the release page was not shown"

echo "2. the same version is up to date"
release v0.10.0
CCF_VERSION=0.10.0 "$CCFINDER" update | grep -q "up to date" || fail "the current version looked out of date"

echo "3. 0.10.0 beats 0.9.0 — numbers, not strings"
release v0.10.0
CCF_VERSION=0.9.0 "$CCFINDER" update | grep -q "update available: 0.10.0" \
  || fail "0.10.0 was not treated as newer than 0.9.0"
release v0.9.0
CCF_VERSION=0.10.0 "$CCFINDER" update | grep -q "up to date" \
  || fail "an older release was offered as an update"

echo "4. a pre-release does not supersede the version it leads up to"
release v1.0.0-beta.1
CCF_VERSION=1.0.0 "$CCFINDER" update | grep -q "up to date" || fail "a beta was offered over the release"
CCF_VERSION=0.10.0 "$CCFINDER" update | grep -q "update available: 1.0.0-beta.1" \
  || fail "a beta was not offered to an older version"

echo "5. what was found is remembered on disk"
release v0.12.0
CCF_VERSION=0.10.0 "$CCFINDER" update >/dev/null
python3 -c "
import json,sys
s=json.load(open('$STATE'))
sys.exit(0 if s['latest']['version']=='0.12.0' and s['lastCheck'] and not s['lastCheckFailed'] else 1)" \
  || fail "the result was not written to update.json"
CCF_VERSION=0.10.0 "$CCFINDER" config | grep -q "0.12.0 is available" \
  || fail "'ccfinder config' does not mention the pending update"

echo "6. --if-due does not look again inside the daily window"
CCF_VERSION=0.10.0 "$CCFINDER" update --if-due | grep -q "checked recently" \
  || fail "a scheduled check ran again straight away"

echo "7. --if-due does look once the window has passed"
python3 - <<PY
import json, datetime
s = json.load(open("$STATE"))
s["lastCheck"] = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(s, open("$STATE", "w"))
PY
CCF_VERSION=0.10.0 "$CCFINDER" update --if-due | grep -q "update available: 0.12.0" \
  || fail "a due check did not run"

echo "8. turning the setting off stops the scheduled check"
"$CCFINDER" config updates off >/dev/null
grep -q '"updateCheck" : false' "$CCF_SUPPORT/config.json" || fail "the setting was not persisted"
"$CCFINDER" config | grep -q "updates      off" || fail "the summary does not show it"
python3 - <<PY
import json, datetime
s = json.load(open("$STATE"))
s["lastCheck"] = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(s, open("$STATE", "w"))
PY
CCF_VERSION=0.10.0 "$CCFINDER" update --if-due | grep -q "update checks are off" \
  || fail "the scheduled check ran with the setting off"

echo "9. an explicit check still works with the setting off"
CCF_VERSION=0.10.0 "$CCFINDER" update | grep -q "update available: 0.12.0" \
  || fail "'ccfinder update' should still answer when asked directly"
"$CCFINDER" config updates on >/dev/null
grep -q '"updateCheck" : true' "$CCF_SUPPORT/config.json" || fail "the setting did not come back on"

echo "10. a check that cannot reach GitHub fails loudly, and retries sooner"
rm "$TMP/latest.json"
if CCF_VERSION=0.10.0 "$CCFINDER" update >"$TMP/out" 2>"$TMP/err"; then
  fail "a failed check exited 0"
fi
grep -q "could not check for updates" "$TMP/err" || fail "no reason was given"
grep -q "up to date" "$TMP/out" && fail "a failed check claimed the app was up to date" || true
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$STATE'))['lastCheckFailed'] is True else 1)" \
  || fail "the failure was not recorded, so the retry window will not apply"
python3 - <<PY
import json, datetime
s = json.load(open("$STATE"))
s["lastCheck"] = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(s, open("$STATE", "w"))
PY
release v0.12.0
CCF_VERSION=0.10.0 "$CCFINDER" update --if-due | grep -q "update available" \
  || fail "a failed check did not retry within the hour"

echo "11. how long ago the check ran is said in plain English"
CCF_VERSION=0.10.0 "$CCFINDER" update >/dev/null
CCF_VERSION=0.10.0 "$CCFINDER" update --if-due | grep -q "last checked just now" \
  || fail "a check that just ran is not reported as 'just now'"
python3 - <<AGED
import json, datetime
s = json.load(open("$STATE"))
s["lastCheck"] = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(s, open("$STATE", "w"))
AGED
CCF_VERSION=0.10.0 "$CCFINDER" update --if-due | grep -q "last checked 3 hours ago" \
  || fail "an older check is not reported in hours"

echo "12. the version the app reports is the one the build stamps on it"
BUILT="$(sed -n 's/.*static let value = "\(.*\)".*/\1/p' "$ROOT/Sources/CCFKit/Update.swift" | head -1)"
[ -n "$BUILT" ] || fail "no version constant found in Sources/CCFKit/Update.swift"
"$CCFINDER" config | grep -q "version      $BUILT" || fail "the CLI reports a different version"

echo
echo "PASS — new releases are reported, older ones are not, the daily window and"
echo "       the setting are respected, and a failed check says so"
