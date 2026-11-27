#!/usr/bin/env python3
"""hex2png.py frame.hex out.png  - converts a 1280x720 RGB444 dump from a testbench to PNG."""
import sys, zlib, struct
vals = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("//")]
W, H = (1280, 720) if len(vals) >= 1280 * 720 else (640, 480)
rows = []
for y in range(H):
    row = bytearray([0])
    base = y * W
    for x in range(W):
        try:
            n = int(vals[base + x], 16) if base + x < len(vals) else 0
        except ValueError:
            n = 0xF0F
        row.extend((((n >> 8) & 15) * 17, ((n >> 4) & 15) * 17, (n & 15) * 17))
    rows.append(bytes(row))
raw = zlib.compress(b"".join(rows), 6)
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
print(f"wrote {W}x{H} PNG ({len(vals)} pixels) -> {sys.argv[2]}")
