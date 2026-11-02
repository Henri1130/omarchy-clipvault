#!/usr/bin/env python3
"""Write a small, ordinary RGB PNG to stdout for tests.

usage: make_png.py WIDTH HEIGHT [R G B] [--text KEY=VALUE] [--ztext KEY=VALUE]

Optional --text/--ztext add an ordinary short metadata chunk (like the
"Software" tag image editors write) so tests can check it gets stripped.
"""
import struct
import sys
import zlib


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    opts = []
    i = 0
    while i < len(argv):
        if argv[i] in ("--text", "--ztext"):
            opts.append((argv[i], argv[i + 1]))
            args.remove(argv[i + 1])
            i += 2
        else:
            i += 1
    width, height = int(args[0]), int(args[1])
    rgb = bytes(int(v) for v in args[2:5]) if len(args) >= 5 else b"\x20\x40\x60"
    raw = b"".join(b"\x00" + rgb * width for _ in range(height))
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    for flag, kv in opts:
        key, value = kv.split("=", 1)
        if flag == "--text":
            out += chunk(b"tEXt", key.encode() + b"\x00" + value.encode())
        else:
            out += chunk(b"zTXt", key.encode() + b"\x00\x00" + zlib.compress(value.encode()))
    out += chunk(b"IDAT", zlib.compress(raw, 9))
    out += chunk(b"IEND", b"")
    sys.stdout.buffer.write(out)


if __name__ == "__main__":
    main(sys.argv[1:])
