#!/bin/bash
# Write clipboard history from stdin under umask 077 so the file is never
# world-readable. FileView atomicWrites cannot do this: it creates a new
# inode with the shell process umask (typically 644).
#
# After the write, drop managed image files that the new history no longer
# references and enforce the image-store byte budget. A short mtime grace
# keeps an in-flight capture.sh persist from being swept before QML records it.
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/clipboard-images"
HISTORY="$STATE_DIR/clipboard-history.json"
PRUNE="$SCRIPT_DIR/prune-images.sh"

mkdir -p "$IMAGE_DIR"
chmod 700 "$IMAGE_DIR" 2>/dev/null || true

tmp=$(mktemp --tmpdir="$STATE_DIR" clipboard-history.XXXXXX)
trap 'rm -f "$tmp"' EXIT
cat >"$tmp"
mv -f "$tmp" "$HISTORY"
trap - EXIT
chmod 600 "$HISTORY"

if [[ -x $PRUNE ]]; then
  "$PRUNE" --sweep --grace-seconds 5 || true
fi
