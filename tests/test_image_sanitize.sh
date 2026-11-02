#!/bin/bash
# sanitize-image.pl: only bounded, structurally valid PNG/JPEG reach Qt, and
# PNG text/ICC/unknown chunks are removed without ever being decompressed.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
san="$root/sanitize-image.pl"
mk="$root/tests/make_png.py"
refute() { if "$@"; then echo "FAIL: expected failure: $*" >&2; exit 1; fi; }

has_chunk() { python3 - "$1" "$2" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read(); p = 8; want = sys.argv[2].encode()
while p + 8 <= len(d):
    n, t = struct.unpack(">I4s", d[p:p + 8])
    if t == want: sys.exit(0)
    p += 12 + n
sys.exit(1)
PY
}

# Plain PNG passes through byte-identical and reports its type.
python3 "$mk" 4 3 >"$tmp/plain.png"
[[ $("$san" "$tmp/plain.png" "$tmp/plain.out") == png ]]
cmp -s "$tmp/plain.png" "$tmp/plain.out"
[[ $(stat -c '%a' "$tmp/plain.out") == 600 ]]

# Ordinary text metadata (tEXt and compressed zTXt) is stripped; pixels kept.
python3 "$mk" 4 3 --text Software=test --ztext Comment=hello >"$tmp/meta.png"
has_chunk "$tmp/meta.png" zTXt
[[ $("$san" "$tmp/meta.png" "$tmp/meta.out") == png ]]
refute has_chunk "$tmp/meta.out" zTXt
refute has_chunk "$tmp/meta.out" tEXt
has_chunk "$tmp/meta.out" IDAT
[[ $(stat -c '%s' "$tmp/meta.out") -lt $(stat -c '%s' "$tmp/meta.png") ]]

# Byte cap: refused before parsing.
python3 "$mk" 64 64 >"$tmp/big.png"
refute env CLIPVAULT_IMAGE_MAX=100 "$san" "$tmp/big.png" "$tmp/big.out" 2>/dev/null
[[ ! -e $tmp/big.out ]]

# Dimension caps, using the header of an ordinary image and a lowered limit.
refute env CLIPVAULT_IMAGE_MAX_SIDE=32 "$san" "$tmp/big.png" "$tmp/side.out" 2>/dev/null
refute env CLIPVAULT_IMAGE_MAX_PIXELS=1000 "$san" "$tmp/big.png" "$tmp/px.out" 2>/dev/null
[[ ! -e $tmp/side.out && ! -e $tmp/px.out ]]

# Bad CRC, truncation, non-images, and non-regular files are refused.
cp "$tmp/plain.png" "$tmp/crc.png"
printf '\x00' | dd of="$tmp/crc.png" bs=1 seek=30 conv=notrunc status=none
refute "$san" "$tmp/crc.png" "$tmp/crc.out" 2>/dev/null
head -c 40 "$tmp/plain.png" >"$tmp/trunc.png"
refute "$san" "$tmp/trunc.png" "$tmp/trunc.out" 2>/dev/null
printf 'fake-png' >"$tmp/fake.png"
refute "$san" "$tmp/fake.png" "$tmp/fake.out" 2>/dev/null
refute "$san" "$tmp" "$tmp/dir.out" 2>/dev/null
mkfifo "$tmp/fifo.png"
refute timeout 3 "$san" "$tmp/fifo.png" "$tmp/fifo.out" 2>/dev/null
[[ ! -e $tmp/crc.out && ! -e $tmp/trunc.out && ! -e $tmp/fake.out && ! -e $tmp/fifo.out ]]

# JPEG: dimensions checked, COM and APPn metadata (except JFIF/Adobe) dropped.
python3 - "$tmp/a.jpg" <<'PY'
import struct, sys
seg = lambda m, body: b"\xff" + bytes([m]) + struct.pack(">H", len(body) + 2) + body
sof = struct.pack(">BHHB", 8, 3, 4, 1) + b"\x01\x11\x00"
data = b"\xff\xd8" + seg(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")
data += seg(0xE1, b"Exif\x00\x00" + b"x" * 20) + seg(0xFE, b"comment")
data += seg(0xC0, sof) + seg(0xDA, b"\x01\x01\x00\x00\x3f\x00") + b"\x12\x34" + b"\xff\xd9"
open(sys.argv[1], "wb").write(data)
PY
[[ $("$san" "$tmp/a.jpg" "$tmp/a.out") == jpg ]]
refute grep -q comment "$tmp/a.out"
refute grep -q Exif "$tmp/a.out"
grep -q JFIF "$tmp/a.out"
refute env CLIPVAULT_IMAGE_MAX_PIXELS=5 "$san" "$tmp/a.jpg" "$tmp/a2.out" 2>/dev/null

echo "ok  sanitize-image.pl bounds and strips images before Qt sees them"
