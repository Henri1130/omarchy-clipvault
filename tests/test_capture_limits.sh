#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp"
unset XDG_STATE_HOME
umask 022

mkdir -p "$tmp/bin"
cat >"$tmp/bin/wl-paste" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --list-types ]]; then
  printf 'text/plain\n'
  exit 0
fi
exit 0
EOF
chmod +x "$tmp/bin/wl-paste"
export PATH="$tmp/bin:$PATH"

TEXT_MAX=1048576
IMAGE_MAX=52428800
capture="$root/capture.sh"

out="$(printf 'hello clipvault' | "$capture" text)"
[[ $out == '{"type":"text","text":"hello clipvault"}' ]]

python3 -c "import sys; sys.stdout.write('a' * $TEXT_MAX)" | "$capture" text >"$tmp/limit.json"
python3 -c "
import json, pathlib
p = pathlib.Path('$tmp/limit.json')
data = json.loads(p.read_text())
assert data['type'] == 'text'
assert data['text'] == 'a' * $TEXT_MAX
"

python3 -c "import sys; sys.stdout.write('a' * ($TEXT_MAX + 1))" | "$capture" text >"$tmp/over.json" || true
[[ ! -s $tmp/over.json ]]

img_dir="$tmp/.local/state/omarchy/clipboard-images"
mkpng="$root/tests/make_png.py"
refute() { if "$@"; then echo "FAIL: expected failure: $*" >&2; exit 1; fi; }

# Malformed image bytes are never persisted or offered for preview.
printf 'fake-png' | "$capture" image/png >"$tmp/fake.json"
[[ ! -s $tmp/fake.json ]]

# Ordinary PNG with text metadata: stored stripped, flagged safe to preview.
python3 "$mkpng" 8 8 --ztext Comment=hello | "$capture" image/png >"$tmp/img.json"
[[ -s $tmp/img.json ]]
[[ $(jq -r .safePreview "$tmp/img.json") == true ]]
stored="$(jq -r .path "$tmp/img.json")"
[[ $stored == "$tmp/.local/state/omarchy/clipboard-images/"*.png ]]
refute grep -q zTXt "$stored"
count_before=$(find "$img_dir" -type f ! -name 'clipboard.*' | wc -l)
[[ $count_before -ge 1 ]]

python3 -c "import sys; sys.stdout.buffer.write(b'x' * ($IMAGE_MAX + 1))" | "$capture" image/png >"$tmp/over-img.json" || true
[[ ! -s $tmp/over-img.json ]]
count_after=$(find "$img_dir" -type f ! -name 'clipboard.*' | wc -l)
[[ $count_after -eq $count_before ]]

# A copied image *file* gets a sanitized managed preview copy; the original
# path is kept for pasting but is never what the overlay loads.
mkdir -p "$tmp/share"
python3 "$mkpng" 6 6 --text Software=x >"$tmp/share/photo one.png"
orig_sum="$(sha256sum "$tmp/share/photo one.png")"
printf 'file://%s' "$tmp/share/photo%20one.png" | "$capture" text >"$tmp/file.json"
[[ $(jq -r .text "$tmp/file.json") == "file://$tmp/share/photo%20one.png" ]]
preview="$(jq -r .preview "$tmp/file.json")"
[[ $preview == "$img_dir/"*.png && -f $preview ]]
refute grep -q tEXt "$preview"
[[ $(sha256sum "$tmp/share/photo one.png") == "$orig_sum" ]]

# Oversized, malformed, non-regular, or non-image files: text entry, no preview.
python3 -c "import sys; sys.stdout.buffer.write(b'\x89PNG' + b'x' * $IMAGE_MAX)" >"$tmp/share/huge.png"
printf 'not an image' >"$tmp/share/fake.png"
mkfifo "$tmp/share/pipe.png"
for f in huge.png fake.png pipe.png missing.png; do
  printf 'file://%s' "$tmp/share/$f" | timeout 5 "$capture" text >"$tmp/nf.json"
  [[ $(jq -r .type "$tmp/nf.json") == text ]]
  [[ $(jq -r 'has("preview")' "$tmp/nf.json") == false ]]
done
rm -f "$tmp/share/huge.png"

# A near-limit (~48 MiB, 16.7 MP) ordinary PNG is stored and kept under the
# 64 MiB store cap; a second one evicts the older file, never itself.
bigpng() {
  python3 - "$1" <<'PY'
import struct, sys, zlib
def chunk(k, d):
    b = k + d
    return struct.pack(">I", len(d)) + b + struct.pack(">I", zlib.crc32(b) & 0xFFFFFFFF)
w = h = 4096
row = b"\x00" + bytes([int(sys.argv[1]), 0x40, 0x60]) * w
raw = row * h
sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 0)) + chunk(b"IEND", b""))
PY
}
bigpng 10 >"$tmp/big1.png"
bigpng 20 >"$tmp/big2.png"
size1=$(stat -c %s "$tmp/big1.png")
(( size1 > 48 * 1024 * 1024 && size1 <= IMAGE_MAX ))
"$capture" image/png <"$tmp/big1.png" >"$tmp/big1.json"
big1="$(jq -r .path "$tmp/big1.json")"
[[ -f $big1 && $(jq -r .safePreview "$tmp/big1.json") == true ]]
sleep 1
"$capture" image/png <"$tmp/big2.png" >"$tmp/big2.json"
big2="$(jq -r .path "$tmp/big2.json")"
[[ -f $big2 && ! -e $big1 ]]
total=$(find "$img_dir" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
(( total <= 64 * 1024 * 1024 ))
[[ -z $(find "$img_dir" -name 'clipboard.*' -print) ]]
rm -f "$tmp/big1.png" "$tmp/big2.png"

echo "ok  capture.sh drops oversized text and images"
