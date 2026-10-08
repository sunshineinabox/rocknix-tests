#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

# mkgpt.py [--msdos] [--start <sector>] <disk> <size MB> <name:MB>...
# Writes the partition table into <disk>, keeping the rest of an existing file.

import os
import struct
import sys
import uuid
import zlib

SECTOR = 512
ENTRIES = 128
ENTRY_SIZE = 128
LINUX_DATA = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")


def header(current, backup, first, last, disk_guid, entries_lba, entries_crc):
    fields = [b"EFI PART", 0x00010000, 92, 0, 0, current, backup, first, last,
              disk_guid.bytes_le, entries_lba, ENTRIES, ENTRY_SIZE, entries_crc]
    raw = struct.pack("<8sIIIIQQQQ16sQIII", *fields)
    fields[3] = zlib.crc32(raw)
    return struct.pack("<8sIIIIQQQQ16sQIII", *fields).ljust(SECTOR, b"\0")


def layout(start, parts):
    for part in parts:
        name, mb = part.split(":")
        end = start + int(mb) * 1024 * 1024 // SECTOR - 1
        yield name, start, end
        start = end + 1


def gpt(f, sectors, start, parts):
    table_sectors = ENTRIES * ENTRY_SIZE // SECTOR
    first, last = 2 + table_sectors, sectors - table_sectors - 2
    entries = b""
    for name, begin, end in layout(start, parts):
        entries += struct.pack("<16s16sQQQ72s", LINUX_DATA.bytes_le, uuid.uuid4().bytes_le, begin, end, 0,
                               name.encode("utf-16-le"))
    entries = entries.ljust(ENTRIES * ENTRY_SIZE, b"\0")
    crc = zlib.crc32(entries)
    disk = uuid.uuid4()
    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(sectors - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    f.write(mbr)
    f.write(header(1, sectors - 1, first, last, disk, 2, crc))
    f.write(entries)
    f.seek((sectors - 1 - table_sectors) * SECTOR)
    f.write(entries)
    f.write(header(sectors - 1, 1, first, last, disk, sectors - 1 - table_sectors, crc))


def msdos(f, start, parts):
    mbr = bytearray(SECTOR)
    mbr[440:444] = os.urandom(4)
    for i, (_, begin, end) in enumerate(layout(start, parts)):
        mbr[446 + 16 * i:462 + 16 * i] = struct.pack("<BBBBBBBBII", 0x80 if i == 0 else 0, 0xFE, 0xFF, 0xFF,
                                                     0x0C if i == 0 else 0x83, 0xFE, 0xFF, 0xFF, begin,
                                                     end - begin + 1)
    mbr[510:512] = b"\x55\xaa"
    f.write(mbr)


def main():
    args = sys.argv[1:]
    label, start = "gpt", 2048
    while args[0].startswith("--"):
        opt = args.pop(0)
        if opt == "--msdos":
            label = "msdos"
        elif opt == "--start":
            start = int(args.pop(0))
    path, size_mb, parts = args[0], int(args[1]), args[2:]
    sectors = size_mb * 1024 * 1024 // SECTOR
    with open(path, "r+b" if os.path.exists(path) else "wb") as f:
        f.truncate(sectors * SECTOR)
        if label == "msdos":
            msdos(f, start, parts)
        else:
            gpt(f, sectors, start, parts)


if __name__ == "__main__":
    main()
