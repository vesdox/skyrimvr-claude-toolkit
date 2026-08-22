#!/bin/bash
set -euo pipefail

TOOLKIT_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &&
    pwd
)"

BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"

ln -sfn \
    "$TOOLKIT_ROOT/tools/skyrim-agent.py" \
    "$BIN_DIR/skyrim-agent"

ln -sfn \
    "$TOOLKIT_ROOT/tools/skyrim-snapshot.py" \
    "$BIN_DIR/skyrim-snapshot"

ln -sfn \
    "$TOOLKIT_ROOT/tools/skyrim-snapshot-set.py" \
    "$BIN_DIR/skyrim-snapshot-set"

echo "Installed Pi/toolkit command links:"
echo "  $BIN_DIR/skyrim-agent"
echo "  $BIN_DIR/skyrim-snapshot"
echo "  $BIN_DIR/skyrim-snapshot-set"
