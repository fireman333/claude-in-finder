#!/bin/bash
# Installing an update from the app: download the release's DMG, check it
# against its checksum and its version, and hand over to the installer inside it
# in a process that outlives the app — the installer stops the app it replaces,
# and launchd stops a job's whole process group when it does.
#
# GitHub is stood in for by a fixture reply and a DMG built here, whose
# install.sh only leaves a mark.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build -c release --package-path "$ROOT" >/dev/null
CCFINDER="$(swift build -c release --show-bin-path --package-path "$ROOT")/ccfinder"
TMP="$(mktemp -d)"
cleanup() {
  for m in "$TMP"/support/updates/mount-*; do
    [ -d "$m" ] && hdiutil detach "$m" -force -quiet 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

export CCF_SUPPORT="$TMP/support"
export CCF_VERSION="0.0.1"
export CCF_UPDATE_API="$TMP/api.json"
export MARK="$TMP/installed"
mkdir -p "$CCF_SUPPORT"

fail() { echo "FAIL: $1"; [ -f "$CCF_SUPPORT/update.log" ] && cat "$CCF_SUPPORT/update.log"; exit 1; }

make_image() {  # make_image <version inside the image> <dmg path>
  local stage="$TMP/stage-$1"
  rm -rf "$stage"; mkdir -p "$stage/Claude in Finder.app/Contents"
  cat > "$stage/Claude in Finder.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$1</string>
</dict></plist>
PLIST
  # Slow on purpose, so the launcher can be killed while it is still running.
  printf '#!/bin/bash\nsleep 3\necho "installed by $0" > "$MARK"\n' > "$stage/install.sh"
  rm -f "$2"
  hdiutil create -quiet -srcfolder "$stage" -volname "Claude in Finder" -format UDZO "$2"
}

reply() {  # reply <tag> <dmg path> <digest or empty>
  python3 - "$CCF_UPDATE_API" "$1" "$2" "$3" <<'EOF'
import json, sys
path, tag, dmg, digest = sys.argv[1:]
asset = {"name": "Claude-in-Finder-%s.dmg" % tag.lstrip("v"),
         "browser_download_url": "file://" + dmg}
if digest:
    asset["digest"] = digest
json.dump({"tag_name": tag, "name": "Claude in Finder " + tag.lstrip("v"),
           "html_url": "https://example.invalid/" + tag, "assets": [asset]},
          open(path, "w"))
EOF
}
sha() { echo "sha256:$(shasum -a 256 "$1" | cut -d' ' -f1)"; }
mounted() { mount | grep -q "$CCF_SUPPORT/updates/mount-" ; }
wait_for_mark() {
  for _ in $(seq 1 40); do [ -f "$MARK" ] && return 0; sleep 0.5; done
  return 1
}

GOOD="$TMP/good.dmg"
make_image "9.9.9" "$GOOD"

echo "1. an image whose checksum does not match is refused, and nothing runs"
reply "v9.9.9" "$GOOD" "sha256:$(printf '0%.0s' $(seq 1 64))"
if "$CCFINDER" update --install >"$TMP/out" 2>&1; then fail "a bad checksum was accepted"; fi
grep -q "does not match" "$TMP/out" || fail "the refusal did not say why: $(cat "$TMP/out")"
[ ! -f "$MARK" ] || fail "the installer ran anyway"
! mounted || fail "the image was left mounted"

echo "2. a release with no checksum is refused"
reply "v9.9.9" "$GOOD" ""
if "$CCFINDER" update --install >"$TMP/out" 2>&1; then fail "an unverifiable image was accepted"; fi
grep -q "no checksum" "$TMP/out" || fail "the refusal did not say why: $(cat "$TMP/out")"

echo "3. an image that is not the announced version is refused"
OTHER="$TMP/other.dmg"
make_image "9.9.8" "$OTHER"
reply "v9.9.9" "$OTHER" "$(sha "$OTHER")"
if "$CCFINDER" update --install >"$TMP/out" 2>&1; then fail "the wrong version was accepted"; fi
grep -q "is not version 9.9.9" "$TMP/out" || fail "the refusal did not say why: $(cat "$TMP/out")"
! mounted || fail "the refused image was left mounted"

echo "4. a good image is installed by its own installer, which outlives whoever started it"
reply "v9.9.9" "$GOOD" "$(sha "$GOOD")"
# Started in a process group of its own, which is then killed outright — what
# launchd does to the agent's job when the installer boots it out.
set -m
( "$CCFINDER" update --install >"$TMP/out" 2>&1; sleep 30 ) &
LAUNCHER=$!
set +m
for _ in $(seq 1 60); do grep -q "installing 9.9.9" "$TMP/out" 2>/dev/null && break; sleep 0.25; done
grep -q "installing 9.9.9" "$TMP/out" || fail "the installer was not started: $(cat "$TMP/out")"
kill -9 -- "-$LAUNCHER" 2>/dev/null || true
# While that installer is still running, a second attempt must stand back
# rather than tidy its image away from under it.
if "$CCFINDER" update --install >"$TMP/second" 2>&1; then fail "a second install ran alongside the first"; fi
grep -q "already being installed" "$TMP/second" || fail "the second attempt did not say why: $(cat "$TMP/second")"
wait_for_mark || fail "the installer died with the process that started it"
for _ in $(seq 1 20); do grep -q "installer finished with status 0" "$CCF_SUPPORT/update.log" 2>/dev/null && break; sleep 0.5; done
grep -q "installer finished with status 0" "$CCF_SUPPORT/update.log" || fail "the hand-over did not finish"
! mounted || fail "the image was not detached afterwards"
[ ! -f "$CCF_SUPPORT/updates/Claude-in-Finder-9.9.9.dmg" ] || fail "the download was not cleaned up"

echo "5. nothing is offered when this is already the latest"
rm -f "$MARK"
OUT="$(CCF_VERSION=9.9.9 "$CCFINDER" update --install 2>&1)"
echo "$OUT" | grep -q "up to date" || fail "expected up to date: $OUT"
[ ! -f "$MARK" ] || fail "an install ran with nothing to install"

echo
echo "PASS — only a verified image of the announced version is installed, and its"
echo "       installer survives the app it replaces being stopped"
