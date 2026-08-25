#!/bin/bash
# Builds from source, then installs for the current user.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/Scripts/build.sh"
bash "$ROOT/Scripts/install-app.sh" "$ROOT/build/Claude in Finder.app"
