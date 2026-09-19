#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp"
unset XDG_STATE_HOME
umask 022

history="$tmp/.local/state/omarchy/clipboard-history.json"
printf '{"secret":"token"}\n' | "$root/save-history.sh"

mode="$(stat -c '%a' "$history")"
dirmode="$(stat -c '%a' "$tmp/.local/state/omarchy/clipboard-images")"
test "$mode" = "600"
test "$dirmode" = "700"
grep -q token "$history"

# A second write must stay 600 even if the process umask is 022.
printf '{"secret":"other"}\n' | "$root/save-history.sh"
test "$(stat -c '%a' "$history")" = "600"
grep -q other "$history"

echo "ok  save-history.sh keeps mode 600"
