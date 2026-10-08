#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import gzip
import json
import os
import shutil
import subprocess
import sys
import tarfile

SQUASHFS_MAGIC = b"hsqs"
GZIP_MAGIC = b"\x1f\x8b"


def magic(path, size):
    with open(path, "rb") as f:
        return f.read(size)


def from_tar(src, work):
    found = set()
    with tarfile.open(src) as tar:
        for member in tar:
            name = os.path.basename(member.name)
            if member.isfile() and name in ("SYSTEM", "KERNEL"):
                with tar.extractfile(member) as f, open(os.path.join(work, name), "wb") as out:
                    shutil.copyfileobj(f, out, 1 << 20)
                found.add(name)
    if "SYSTEM" not in found:
        sys.exit(f"no SYSTEM in {src}")


def from_img(src, work):
    img = src
    if magic(src, 2) == GZIP_MAGIC:
        img = os.path.join(work, "image.img")
        with gzip.open(src, "rb") as f, open(img, "wb") as out:
            shutil.copyfileobj(f, out, 1 << 20)
    table = json.loads(subprocess.check_output(["sfdisk", "-J", img]))["partitiontable"]
    sector = table.get("sectorsize", 512)
    for part in table["partitions"]:
        offset = part["start"] * sector
        listing = subprocess.run(["mdir", "-b", "-i", f"{img}@@{offset}", "::"],
                                 capture_output=True, text=True)
        if listing.returncode == 0 and "::/SYSTEM" in listing.stdout.split():
            for name in ("SYSTEM", "KERNEL"):
                if f"::/{name}" in listing.stdout.split():
                    subprocess.check_call(["mcopy", "-n", "-i", f"{img}@@{offset}", f"::{name}",
                                           os.path.join(work, name)])
            break
    else:
        sys.exit(f"no SYSTEM on any FAT partition of {src}")
    if img != src:
        os.unlink(img)


def main():
    src, work = sys.argv[1], sys.argv[2]
    dest = os.path.join(work, "SYSTEM")
    if magic(src, 4) == SQUASHFS_MAGIC:
        shutil.copyfile(src, dest)
    elif tarfile.is_tarfile(src):
        from_tar(src, work)
    else:
        from_img(src, work)
    release = subprocess.check_output(["unsquashfs", "-cat", dest, "etc/os-release"], text=True)
    print(release, end="")


if __name__ == "__main__":
    main()
