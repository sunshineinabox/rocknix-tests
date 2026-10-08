#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import lzma
import shutil
import struct
import subprocess
import sys
import zlib

NEWC = b"070701"
TRAILER = b"TRAILER!!!"
TOOLS = {b"\x28\xb5\x2f\xfd": "zstd", b"\x89LZO\x00": "lzop", b"\x02\x21\x4c\x18": "lz4"}
COMPRESSED = (b"\x1f\x8b\x08", b"\xfd7zXZ\x00") + tuple(TOOLS)


def unwrap_android(data):
    if not data.startswith(b"ANDROID!"):
        return data
    kernel_size, _, ramdisk_size = struct.unpack_from("<III", data, 8)
    page_size = struct.unpack_from("<I", data, 36)[0]
    kernel = data[page_size:page_size + kernel_size]
    if ramdisk_size > 4096:
        start = page_size + (kernel_size + page_size - 1) // page_size * page_size
        return data[start:start + ramdisk_size]
    return kernel


def decompress(data):
    try:
        if data.startswith(b"\x1f\x8b"):
            return zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(data)
        if data.startswith(b"\xfd7zXZ"):
            return lzma.LZMADecompressor().decompress(data)
        for magic, tool in TOOLS.items():
            if data.startswith(magic) and shutil.which(tool):
                return subprocess.run([tool, "-dc"], input=data, capture_output=True).stdout
    except (zlib.error, lzma.LZMAError):
        return b""
    return data


def cpio_end(data, offset):
    entries = 0
    while data.startswith(NEWC, offset):
        header = data[offset:offset + 110]
        try:
            size = int(header[54:62], 16)
            namesize = int(header[94:102], 16)
        except ValueError:
            return None, 0
        name_end = offset + 110 + namesize
        name = data[offset + 110:name_end - 1]
        data_start = (name_end + 3) & ~3
        offset = (data_start + size + 3) & ~3
        if name == TRAILER:
            return offset, entries
        entries += 1
    return None, 0


def find_cpio(data):
    best = None
    start = data.find(NEWC)
    while start != -1:
        end, entries = cpio_end(data, start)
        if end and entries > 10 and (best is None or entries > best[2]):
            best = (start, end, entries)
        start = data.find(NEWC, end if end else start + 1)
    return best


def find_compressed_cpio(data):
    for magic in COMPRESSED:
        offset = data.find(magic)
        while offset != -1:
            inner = decompress(data[offset:])
            if inner.startswith(NEWC):
                found = find_cpio(inner)
                if found:
                    return inner, found
            offset = data.find(magic, offset + 1)
    return None, None


def main():
    kernel, out = sys.argv[1], sys.argv[2]
    data = decompress(unwrap_android(open(kernel, "rb").read()))
    found = find_cpio(data)
    if not found:
        data, found = find_compressed_cpio(data)
    if not found:
        sys.exit(f"no built-in initramfs in {kernel}")
    start, end, entries = found
    with open(out, "wb") as f:
        f.write(data[start:end])
    print(f"initramfs: {entries} entries", file=sys.stderr)


if __name__ == "__main__":
    main()
