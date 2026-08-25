#!/bin/bash
# Runs the whole suite against synthetic session data.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in rename-test watch-test archive-delete-test config-test multi-select-test update-test preview-test; do
  echo "── $t ─────────────────────────────"
  bash "$HERE/$t.sh"
  echo
done
echo "all tests passed"
