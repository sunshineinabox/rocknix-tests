#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import argparse
import collections
import json
import os
import re
import sys

RESULT = re.compile(r"^(ok|not ok) \d+ - (?:([\w-]+): )?(.+?)(?: # (TODO|SKIP)\b ?(.*))?$")
PLAN = re.compile(r"^1\.\.(\d+)$")
KEYS = ("pass", "fail", "skip", "xfail", "stale")


def parse(path):
    counts = dict.fromkeys(KEYS, 0)
    failed, stale, skipped, planned, ran, current = [], [], [], 0, 0, None
    for raw in open(path, errors="replace"):
        line = raw.rstrip("\n")
        line = re.sub(r"^\S+Z ", "", line)
        if m := PLAN.match(line):
            planned += int(m.group(1))
            continue
        if m := RESULT.match(line):
            ran += 1
            state, suite, name, directive, reason = m.groups()
            test = f"{suite}: {name}" if suite else name
            current = None
            if directive == "SKIP":
                counts["skip"] += 1
                skipped.append(f"{test} ({reason})")
            elif directive == "TODO":
                key = "stale" if state == "ok" else "xfail"
                counts[key] += 1
                if key == "stale":
                    stale.append(test)
            elif state == "ok":
                counts["pass"] += 1
            else:
                counts["fail"] += 1
                current = {"test": test, "detail": []}
                failed.append(current)
            continue
        if current is not None and line.startswith("#   ") and len(current["detail"]) < 25:
            current["detail"].append(line[4:])
        elif not line.startswith("#   "):
            current = None
    counts.update(planned=planned, ran=ran)
    return counts, failed, stale, skipped


def job(args):
    parts, failed, stale, skipped = {}, [], [], []
    for spec in args.parts:
        name, path = spec.split("=", 1)
        if not os.path.exists(path):
            continue
        counts, f, s, k = parse(path)
        parts[name] = counts
        failed += f
        stale += s
        skipped += k
    title = f"### {args.device}" + (f" ({args.image})" if args.image else "")
    out = [title, ""]
    if not parts:
        out.append("No test results.")
    else:
        out += ["| Part | Pass | Fail | Skip | Expected failures | Passing but in xfail | Ran |",
                "|---|---:|---:|---:|---:|---:|---:|"]
        for name, c in parts.items():
            if not c["ran"]:
                out.append(f"| {name} | no results | | | | | |")
                continue
            ran = f"{c['ran']}/{c['planned']}" if c["planned"] and c["ran"] != c["planned"] else str(c["ran"])
            out.append(f"| {name} | {c['pass']} | {c['fail']} | {c['skip']} | {c['xfail']} | {c['stale']} | {ran} |")
    incomplete = [n for n, c in parts.items() if not c["ran"] or c["ran"] < c["planned"]]
    if incomplete:
        out += ["", "**Stopped early:** " + ", ".join(
            f"{n} ran {parts[n]['ran']} of {parts[n]['planned']}" if parts[n]["planned"] else f"{n} produced no results"
            for n in incomplete)]
    if failed:
        out += ["", "**Failed**", ""]
        for f in failed:
            out += [f"<details><summary>{f['test']}</summary>", "", "```", *f["detail"], "```", "</details>"]
    if stale:
        out += ["", "**Passing but listed in tests/xfail**", ""] + [f"- {s}" for s in stale]
    if skipped:
        out += ["", "<details><summary>Skipped</summary>", ""] + [f"- {s}" for s in skipped] + ["</details>"]
    if args.artifact:
        out += ["", f"Logs and the boot screenshot are in the `{args.artifact}` artifact."]
    print("\n".join(out) + "\n")
    if args.json:
        with open(args.json, "w") as fp:
            json.dump({"device": args.device, "image": args.image, "parts": parts,
                       "failed": [f["test"] for f in failed],
                       "stale": stale, "incomplete": incomplete}, fp, indent=1)


def cell(c):
    if c is None:
        return ""
    if not c["ran"]:
        return "no results"
    if c["planned"] and c["ran"] < c["planned"]:
        return f"stopped at {c['ran']}/{c['planned']}"
    if c["fail"]:
        return f"**{c['fail']} failed**"
    return f"{c['pass']} passed"


def report(args):
    results = []
    for path in args.files:
        with open(path) as fp:
            results.append(json.load(fp))
    results.sort(key=lambda r: r["device"])
    names = []
    for r in results:
        names += [n for n in r["parts"] if n not in names]
    out = ["## Results", ""]
    if not results:
        print("\n".join(out + ["No device reported results."]))
        return
    out += ["| Device | Image | " + " | ".join(names) + " |", "|---|---|" + "---|" * len(names)]
    for r in results:
        out.append(f"| {r['device']} | {r['image'] or ''} | " + " | ".join(cell(r["parts"].get(n)) for n in names) + " |")
    for key, title in (("failed", "Failures"), ("stale", "Passing but listed in tests/xfail")):
        by_test = collections.defaultdict(list)
        for r in results:
            for t in r[key]:
                by_test[t].append(r["device"])
        if by_test:
            out += ["", f"**{title}**", ""]
            for t, devices in sorted(by_test.items(), key=lambda kv: (-len(kv[1]), kv[0])):
                where = "all devices" if len(devices) == len(results) > 1 else ", ".join(devices)
                out.append(f"- {t}: {where}")
    print("\n".join(out) + "\n")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)
    j = sub.add_parser("job")
    j.add_argument("--device", required=True)
    j.add_argument("--image", default="")
    j.add_argument("--artifact", default="")
    j.add_argument("--json")
    j.add_argument("parts", nargs="*", help="name=tap-file")
    r = sub.add_parser("report")
    r.add_argument("files", nargs="*")
    args = p.parse_args()
    (job if args.mode == "job" else report)(args)


if __name__ == "__main__":
    sys.exit(main())
