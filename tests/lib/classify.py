#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import os
import re
import subprocess
import sys

BUILD_PATHS = re.compile(
    r"(\.patch$|/patches/|^config/|^scripts/(?!test$)|^distributions/|^packages/|/linux/[^/]*\.conf$"
    r"|^projects/[^/]+/(devices/[^/]+/)?options$|/initramfs/|/busybox/scripts/(init|functions)$"
    r"|\.(c|h|cc|cpp|rs|go)$)")
BUILD_KEYS = re.compile(r"^[+-]\s*(PKG_(?!LONGDESC|SITE|LICENSE|SECTION|SHORTDESC)\w+=|"
                        r"(pre_|post_)?(configure|make|build|unpack|patch)_(target|host|init)\s*\(\))")
INSTALL_FUNCS = re.compile(r"(pre_|post_)?(makeinstall_target|post_install|post_makeinstall_target)\b")
BUILD_FUNCS = re.compile(r"(pre_|post_)?(configure|make|build|unpack|patch|makeinstall_init)_?\w*\s*\(\)")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def package_mk_needs_build(base, path):
    for line in git("diff", "-U0", "--no-color", base, "--", path).splitlines():
        if line.startswith(("+++", "---")):
            continue
        if line.startswith("@@"):
            func = line.split("@@", 2)[-1].strip()
            if func and BUILD_FUNCS.search(func) and not INSTALL_FUNCS.search(func):
                return f"{path}: changes inside {func}"
        elif BUILD_KEYS.match(line):
            return f"{path}: {line.strip()}"
    return None


def main():
    repo, ref = sys.argv[1], sys.argv[2]
    os.chdir(repo)
    base = git("merge-base", ref, "HEAD").strip()
    changed = git("diff", "--name-only", base).splitlines()
    changed += git("ls-files", "--others", "--exclude-standard").splitlines()
    reasons = []
    for path in changed:
        if path.startswith((".github/", "tests/")) or path == "scripts/test":
            continue
        if BUILD_PATHS.search(path):
            reasons.append(f"{path}: needs a build")
        elif path.endswith("/package.mk"):
            reason = package_mk_needs_build(base, path)
            if reason:
                reasons.append(reason)
    for reason in reasons:
        print(reason, file=sys.stderr)
    print("build" if reasons else "overlay")


if __name__ == "__main__":
    main()
