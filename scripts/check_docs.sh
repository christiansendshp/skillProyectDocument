#!/usr/bin/env sh
# Backward-compatible launcher.
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/project_docs.sh" check "${1:-.}"
