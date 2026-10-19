#!/bin/bash
# Copy one ClipVault entry to the clipboard and paste it into the window that
# was focused when the overlay opened.
#
#   paste.sh [--copy-only] [--window 0xADDR] --text          < exact text on stdin
#   paste.sh [--copy-only] [--window 0xADDR] --file MIME PATH
#
# QML pipes the entry's full text straight from its in-memory history, so the
# paste never depends on clipboard-history.json being saved yet, and the capped
# display text is never what gets pasted. With the mouse, the pointer sits over
# the overlay when it closes and follow_mouse can hand focus to whatever window
# is under it; refocusing the remembered window first keeps the paste on target.

set -uo pipefail

copy_only=false
window=""
mode=""
mime=""
path=""

while (( $# > 0 )); do
  case "$1" in
    --copy-only) copy_only=true; shift ;;
    --window) window="${2:-}"; shift 2 ;;
    --text) mode=text; shift ;;
    --file) mode=file; mime="${2:-}"; path="${3:-}"; shift 3 ;;
    *) echo "paste.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

paste_delay=${CLIPVAULT_PASTE_DELAY:-0.12}
focus_delay=${CLIPVAULT_FOCUS_DELAY:-0.05}

case "$mode" in
text)
  tmp=$(mktemp --tmpdir clipvault-paste.XXXXXX) || exit 1
  trap 'rm -f "$tmp"' EXIT
  chmod 600 "$tmp"
  cat >"$tmp"
  [[ -s $tmp ]] || exit 1
  wl-copy <"$tmp" || exit 1
  ;;
file)
  [[ $mime =~ ^[a-z]+/[a-z0-9.+-]+$ ]] || exit 1
  [[ -f $path && -r $path ]] || exit 1
  wl-copy --type "$mime" <"$path" || exit 1
  ;;
*)
  echo "paste.sh: need --text or --file MIME PATH" >&2
  exit 2
  ;;
esac

[[ $copy_only == true ]] && exit 0

sleep "$paste_delay"

# Only a bare Hyprland hex address may reach the Lua dispatcher.
if [[ $window =~ ^0x[0-9a-fA-F]+$ ]]; then
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$window\" })" >/dev/null 2>&1 || true
  sleep "$focus_delay"
fi

wtype -M shift -k Insert -m shift 2>/dev/null || true
