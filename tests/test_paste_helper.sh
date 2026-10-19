#!/bin/bash
# paste.sh: exact stdin text / image file -> wl-copy, refocus the remembered
# window, then Shift+Insert. Runs against stub wl-copy/wtype/hyprctl so it never
# touches the real clipboard or the live session.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
log="$tmp/calls.log"
export STUB_LOG="$log" STUB_DIR="$tmp"
cat >"$tmp/bin/wl-copy" <<'S'
#!/bin/bash
printf 'wl-copy %s\n' "$*" >>"$STUB_LOG"
cat >"$STUB_DIR/copied"
S
cat >"$tmp/bin/wtype" <<'S'
#!/bin/bash
printf 'wtype %s\n' "$*" >>"$STUB_LOG"
S
cat >"$tmp/bin/hyprctl" <<'S'
#!/bin/bash
printf 'hyprctl %s\n' "$*" >>"$STUB_LOG"
echo ok
S
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export CLIPVAULT_PASTE_DELAY=0 CLIPVAULT_FOCUS_DELAY=0

fail() { echo "FAIL: $*" >&2; [[ -f $log ]] && cat "$log" >&2; exit 1; }
reset() { rm -f "$log" "$tmp/copied"; touch "$log"; }

# 1. Exact text bytes survive: leading dash, unicode, trailing newline, no extra newline.
reset
text=$'-n --not-an-option\n  Ünïcödé 🍟\ttab\n'
printf '%s' "$text" | "$root/paste.sh" --text --window 0x593bd871e490
cmp -s <(printf '%s' "$text") "$tmp/copied" || fail "text bytes changed"
grep -qx 'wl-copy ' "$log" || fail "text should use plain wl-copy (auto mime, like stock)"
focus_line=$(grep -n '^hyprctl dispatch hl.dsp.focus({ window = "address:0x593bd871e490" })$' "$log" | cut -d: -f1)
wtype_line=$(grep -n '^wtype -M shift -k Insert -m shift$' "$log" | cut -d: -f1)
[[ -n $focus_line && -n $wtype_line ]] || fail "missing focus or wtype"
(( focus_line < wtype_line )) || fail "focus must happen before Shift+Insert"

# 2. Large text (beyond argv limits) is piped intact.
reset
head -c 600000 /dev/urandom | base64 -w 76 >"$tmp/big"
"$root/paste.sh" --text <"$tmp/big"
cmp -s "$tmp/big" "$tmp/copied" || fail "large text changed"
grep -q '^hyprctl' "$log" && fail "no --window must not refocus"
grep -q '^wtype' "$log" || fail "paste without window still sends Shift+Insert"

# 3. --copy-only copies but never refocuses or types.
reset
printf 'copy me' | "$root/paste.sh" --copy-only --text --window 0xabc
[[ $(<"$tmp/copied") == "copy me" ]] || fail "copy-only text"
grep -qE '^(hyprctl|wtype)' "$log" && fail "copy-only must not focus/type"

# 4. A malformed window address is ignored (no Lua injection), paste still works.
reset
printf 'x' | "$root/paste.sh" --text --window '0x1" }) os.exit() --'
grep -q '^hyprctl' "$log" && fail "bad address reached hyprctl"
grep -q '^wtype' "$log" || fail "bad address should still paste"

# 5. Images: copy with explicit mime from file, then paste.
reset
printf '\x89PNGfake' >"$tmp/i.png"
"$root/paste.sh" --file image/png "$tmp/i.png" --window 0xabc
cmp -s "$tmp/i.png" "$tmp/copied" || fail "image bytes"
grep -qx 'wl-copy --type image/png' "$log" || fail "image mime"
grep -q '^wtype' "$log" || fail "image paste"

# 6. Missing image or empty text: nothing copied, nothing typed, non-zero exit.
reset
if "$root/paste.sh" --file image/png "$tmp/missing.png"; then fail "missing image should fail"; fi
if printf '' | "$root/paste.sh" --text; then fail "empty text should fail"; fi
[[ -s $log ]] && fail "nothing should run on failure"

# 7. Bad mime is refused.
reset
if "$root/paste.sh" --file 'text/html; x' "$tmp/i.png"; then fail "bad mime accepted"; fi

echo "ok  paste.sh copies exact payloads, refocuses, then pastes"
