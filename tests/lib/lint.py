#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scan_commands import is_shell

ASH = (re.compile(r"^projects/ROCKNIX/packages/sysutils/busybox/scripts/(init|functions)$"),
       re.compile(r"^projects/ROCKNIX/devices/[^/]+/bootloader/update\.sh$"))
EXCLUDE = "SC1090,SC1091,SC2034,SC2154,SC2155,SC2164,SC2148"


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout


def changed_lines(repo, base):
    merge_base = git(repo, "merge-base", base, "HEAD").strip()
    lines, current = {}, None
    for row in git(repo, "diff", "-U0", "--no-color", merge_base, "--", "projects").splitlines():
        if row.startswith("+++ "):
            current = row[6:].rstrip("\t").strip('"') if row.startswith("+++ b/") else None
        elif row.startswith("@@") and current:
            m = re.search(r"\+(\d+)(?:,(\d+))?", row)
            start, count = int(m.group(1)), int(m.group(2) or 1)
            lines.setdefault(current, set()).update(range(start, start + count))
    for path in git(repo, "ls-files", "--others", "--exclude-standard", "--", "projects").splitlines():
        lines[path] = None
    return lines


def files(repo, base):
    if base:
        candidates = list(changed_lines(repo, base))
    else:
        candidates = git(repo, "ls-files", "--", "projects/ROCKNIX").splitlines()
    for rel in sorted(candidates):
        path = os.path.join(repo, rel)
        if os.path.isfile(path) and not os.path.islink(path) and is_shell(path):
            dialect = "busybox" if any(p.match(rel) for p in ASH) else "bash"
            print(f"{dialect}\t{rel}")


def comments(paths):
    decoder = json.JSONDecoder()
    for path in paths:
        text, pos = open(path).read(), 0
        while True:
            while pos < len(text) and text[pos].isspace():
                pos += 1
            if pos == len(text):
                break
            doc, pos = decoder.raw_decode(text, pos)
            yield from doc.get("comments", [])


def report(repo, base, results):
    lines = changed_lines(repo, base) if base else None
    found = 0
    for item in sorted(comments(results), key=lambda c: (c["file"], c["line"], c["column"])):
        rel = os.path.relpath(item["file"], "/repo")
        if lines is not None:
            wanted = lines.get(rel, set())
            if wanted is not None and item["line"] not in wanted:
                continue
        found += 1
        print(f"{rel}:{item['line']}:{item['column']}: {item['level']}: {item['message']} [SC{item['code']}]")
    print(f"{found} finding(s)", file=sys.stderr)
    return 1 if found else 0


def main():
    args = sys.argv[1:]
    if args[:1] == ["exclude"]:
        print(EXCLUDE)
    elif len(args) >= 2 and args[0] == "files":
        files(args[1], args[2] if len(args) > 2 else None)
    elif len(args) >= 4 and args[0] == "report":
        sys.exit(report(args[1], None if args[2] == "--all" else args[2], args[3:]))
    else:
        sys.exit("usage: lint.py files <repo> [base] | report <repo> <base|--all> <json>... | exclude")


if __name__ == "__main__":
    main()
