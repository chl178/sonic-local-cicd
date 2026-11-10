#!/usr/bin/env python3
"""Minimal PPM (P6) -> PNG converter using only the stdlib, for viewing
QEMU monitor screendumps on hosts without PIL/ImageMagick."""
import struct, sys, zlib

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # Parse header: P6, whitespace-separated width/height/maxval, single
    # whitespace, then raw RGB data.
    if data[:2] != b"P6":
        raise SystemExit("not a P6 PPM: %r" % data[:2])
    idx, fields = 2, []
    while len(fields) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        if data[idx:idx+1] == b"#":
            while data[idx:idx+1] not in (b"\n", b""):
                idx += 1
            continue
        start = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        fields.append(int(data[start:idx]))
    idx += 1  # single whitespace before raster
    w, h, maxval = fields
    raster = data[idx:idx + w * h * 3]
    return w, h, raster

def chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload +
            struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

def main():
    w, h, raster = read_ppm(sys.argv[1])
    raw = b"".join(b"\x00" + raster[y*w*3:(y+1)*w*3] for y in range(h))
    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(raw, 9)) +
           chunk(b"IEND", b""))
    with open(sys.argv[2], "wb") as f:
        f.write(png)
    print("wrote %s (%dx%d)" % (sys.argv[2], w, h))

main()
