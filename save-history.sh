#!/bin/bash
# Write clipboard history from stdin under umask 077 so the file is never
# world-readable. FileView atomicWrites cannot do this: it creates a new
# inode with the shell process umask (typically 644).
set -euo pipefail
umask 077

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/clipboard-images"
HISTORY="$STATE_DIR/clipboard-history.json"

mkdir -p "$IMAGE_DIR"
chmod 700 "$IMAGE_DIR" 2>/dev/null || true

tmp=$(mktemp --tmpdir="$STATE_DIR" clipboard-history.XXXXXX)
trap 'rm -f "$tmp"' EXIT
cat >"$tmp"
mv -f "$tmp" "$HISTORY"
trap - EXIT
chmod 600 "$HISTORY"
