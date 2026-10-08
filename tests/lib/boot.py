#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import argparse
import collections
import gzip
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

UNIT = """[Unit]
Description=ROCKNIX boot test
After=default.target

[Service]
Type=oneshot
StandardOutput=journal+console
ExecStart=/bin/sh /storage/.rocknix-boot-test
"""

# sway-init only finds the card through DSI/DP/HDMI connectors and libmali cannot drive virtio-gpu
DISPLAY_FILES = {
    "/.config/system.d/sway.service.d/rocknix-boot-test.conf":
        "[Service]\nEnvironmentFile=/storage/.rocknix-boot-test.env\n",
    "/.rocknix-boot-test.env": "WLR_DRM_DEVICES=/dev/dri/card0\n",
    "/.config/system.d/rocknix-autostart.service.d/rocknix-boot-test.conf":
        "[Service]\nExecStartPre=-/bin/sh -c '[ ! -x /usr/bin/gpudriver ] || /usr/bin/gpudriver panfrost'\n",
}

UI_UNITS = ["sway.service", "essway.service", "emustation.service", "kwin.service"]

SHELL_ONLY = ("command not found|unary operator expected|binary operator expected|integer expression expected|"
              "syntax error|bad substitution|too many arguments|ambiguous redirect|unbound variable|unknown operand|"
              "bad number")
ERRNO = "No such file or directory|Permission denied"
ERRORS = f"{SHELL_ONLY}|{ERRNO}|not found|can't"
SHELL_ERROR = re.compile(rf"({SHELL_ONLY})|^[^ :]+:( line)? [0-9]+: .*({ERRNO}|: not found|can't open|can't create)|"
                         rf"^[a-z0-9_.+-]+: (can't |cannot |mounting |[/'\"]).*({ERRNO})")

SETTLE = """i=0
while [ $i -lt 150 ]; do
  left=$(systemctl list-jobs --no-legend --plain 2>/dev/null | grep -v rocknix-boot-test | grep -c .)
  [ "$left" = 0 ] && break
  sleep 2
  i=$((i + 1))
done
echo "ROCKNIX-BOOT jobs-left=$left"
systemctl list-jobs --no-legend --plain | grep -v rocknix-boot-test | sed "s|^|ROCKNIX-BOOT job: |"
"""

DISPLAY = """export XDG_RUNTIME_DIR=/var/run/0-runtime-dir WAYLAND_DISPLAY=wayland-1
i=0
while [ $i -lt 60 ]; do
  es=$(pgrep -x emulationstation)
  [ -n "$es" ] && sleep 4 && [ "$(pgrep -x emulationstation)" = "$es" ] && break
  sleep 2
  i=$((i + 1))
done
for p in sway kwin_wayland emulationstation; do
  pgrep -x $p >/dev/null && echo "ROCKNIX-BOOT running: $p"
done
for c in /sys/class/drm/card*-*; do
  [ -e "$c/status" ] && echo "ROCKNIX-BOOT connector: ${c##*/} $(cat $c/status) $(cat $c/enabled)"
done
grep -E "ERROR|failed" /var/log/es_log.txt 2>/dev/null | tail -n 5 | sed "s|^|ROCKNIX-BOOT es: |"
echo "ROCKNIX-BOOT screendump"
read -r -t 60 ack </dev/console
"""

REPORT = """systemctl list-units --failed --no-legend --plain | while read -r unit rest; do
  echo "ROCKNIX-BOOT failed: $unit"
  journalctl -b -u "$unit" --no-pager -o cat -n 12 | sed "s|^|ROCKNIX-BOOT log $unit: |"
done
journalctl -b -q --no-pager _TRANSPORT=stdout -o json --output-fields=_SYSTEMD_UNIT,MESSAGE |
  grep -E "$ERRORS" | sed "s|^|ROCKNIX-BOOT journal |"
grep -E "$ERRORS" /var/log/boot.log 2>/dev/null | sed "s|^|ROCKNIX-BOOT boot.log |"
echo "ROCKNIX-BOOT done"
systemctl poweroff
"""


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def raw_disk(image, work):
    disk = os.path.join(work, "disk.img")
    opener = gzip.open if open(image, "rb").read(2) == b"\x1f\x8b" else open
    with opener(image, "rb") as f, open(disk, "wb") as out:
        shutil.copyfileobj(f, out, 1 << 20)
        out.truncate(out.tell() + (2 << 30))
    if json.loads(run("sfdisk", "-J", disk))["partitiontable"]["label"] == "gpt":
        run("sfdisk", "--relocate", "gpt-bak-std", disk)
    return disk


def partitions(disk):
    table = json.loads(run("sfdisk", "-J", disk))["partitiontable"]
    sector = table.get("sectorsize", 512)
    return [(n, p["start"] * sector, p["size"] * sector) for n, p in enumerate(table["partitions"], 1)]


def prepare_storage(disk, work, files):
    image = os.path.join(work, "part.img")
    for n, offset, size in partitions(disk):
        run("dd", f"if={disk}", f"of={image}", "bs=1M", f"skip={offset}", f"count={size}",
            "iflag=skip_bytes,count_bytes", "conv=sparse")
        label = subprocess.run(["blkid", "-o", "value", "-s", "LABEL", image], capture_output=True,
                               text=True).stdout.strip()
        if label != "STORAGE":
            continue
        if n == len(partitions(disk)):
            run("sfdisk", "-q", "-N", str(n), disk, input=", +\n")
            _, offset, size = partitions(disk)[n - 1]
            with open(image, "r+b") as f:
                f.truncate(size)
            subprocess.run(["e2fsck", "-fy", image], capture_output=True)
            run("resize2fs", image)
        commands = ["rm /.please_resize_me"]
        dirs = set()
        for i, (path, content) in enumerate(sorted(files.items())):
            parent = os.path.dirname(path)
            missing = []
            while parent != "/" and parent not in dirs:
                missing.insert(0, parent)
                parent = os.path.dirname(parent)
            dirs.update(missing)
            commands += [f"mkdir {d}" for d in missing]
            src = os.path.join(work, f"file{i}")
            with open(src, "w") as f:
                f.write(content)
            commands.append(f"write {src} {path}")
        with open(os.path.join(work, "debugfs"), "w") as f:
            f.write("\n".join(commands) + "\n")
        subprocess.run(["debugfs", "-w", "-f", os.path.join(work, "debugfs"), image], capture_output=True)
        run("dd", f"if={image}", f"of={disk}", "bs=1M", f"seek={offset}", "oflag=seek_bytes", "conv=notrunc,sparse")
        os.unlink(image)
        return
    sys.exit("no STORAGE partition in the image")


def qmp(path, command, **arguments):
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(path)
        f = s.makefile("rw")
        f.readline()
        for c in [{"execute": "qmp_capabilities"}, {"execute": command, "arguments": arguments}]:
            f.write(json.dumps(c) + "\n")
            f.flush()
            while "event" in (reply := json.loads(f.readline())):
                pass
        return reply


def dominant(ppm):
    with open(ppm, "rb") as f:
        data = f.read()
    header = re.match(rb"P6\s+(\d+)\s+(\d+)\s+\d+\s", data)
    width, height, pixels = int(header[1]), int(header[2]), data[header.end():]
    counts = collections.Counter(pixels[i:i + 3] for i in range(0, width * height * 3, 3 * 7))
    return counts.most_common(1)[0][1] / sum(counts.values())


def screendump(args, sock):
    ppm = os.path.join(args.work, "screen.ppm")
    share = 1.0
    start = time.time()
    while time.time() - start < 30:
        if "error" not in qmp(sock, "screendump", filename=ppm) and os.path.exists(ppm):
            share = dominant(ppm)
            if share < 0.9:
                break
        time.sleep(1)
    qmp(sock, "screendump", filename=args.screenshot, format="png")
    print(f"# screendump after {time.time() - start:.0f}s, {share:.0%} of the screen is one color")
    return share


def boot(args, disk, log):
    cmdline = [
        "boot=LABEL=ROCKNIX", "disk=LABEL=STORAGE", "console=ttyAMA0", "loglevel=4", "panic=5",
        "systemd.wants=rocknix-boot-test.service", "systemd.show_status=1", "vkms.create_default_dev=0",
    ]
    qemu = ["qemu-system-aarch64", "-M", "virt,gic-version=3", "-cpu", "max", "-smp", str(args.cpus),
            "-m", str(args.memory), "-nographic", "-nic", "none", "-kernel", args.kernel, "-initrd", args.initrd,
            "-drive", f"file={disk},format=raw,if=none,id=hd", "-device", "virtio-blk-device,drive=hd",
            "-device", "virtio-rng-device", "-device", "virtio-gpu-pci"]
    sock = os.path.join(args.work, "qmp.sock")
    if args.display:
        qemu += ["-qmp", f"unix:{sock},server=on,wait=off"]
    else:
        cmdline += [f"systemd.mask={u}" for u in UI_UNITS]
    qemu += ["-append", " ".join(cmdline)]
    lines = []
    share = None
    start = time.time()
    with open(log, "w") as out:
        proc = subprocess.Popen(qemu, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.PIPE)
        os.set_blocking(proc.stdout.fileno(), False)
        buf = b""
        while proc.poll() is None and time.time() - start < args.timeout:
            chunk = proc.stdout.read() or b""
            if not chunk:
                time.sleep(0.2)
                continue
            buf += chunk
            *done, buf = buf.split(b"\n")
            for raw in done:
                line = raw.decode(errors="replace").rstrip("\r")
                out.write(line + "\n")
                lines.append(line)
                if args.display and "ROCKNIX-BOOT screendump" in line:
                    try:
                        share = screendump(args, sock)
                    except OSError as e:
                        print(f"# screendump failed: {e}")
                    proc.stdin.write(b"\n")
                    proc.stdin.flush()
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        os.set_blocking(proc.stdout.fileno(), True)
        buf += proc.stdout.read() or b""
        for raw in buf.split(b"\n"):
            line = raw.decode(errors="replace").rstrip("\r")
            if line:
                out.write(line + "\n")
                lines.append(line)
    return lines, share, time.time() - start


def known_lines(path):
    if not path or not os.path.exists(path):
        return []
    return [l.strip() for l in open(path) if l.strip()]


def matcher(lines):
    patterns = [re.compile(re.escape(k).replace(r"\*", ".*") + "$") for k in lines]
    return lambda line: any(p.match(line) for p in patterns)


def xfail_lines(known):
    return known_lines(known[:-len(".known")] + ".xfail") if known.endswith(".known") else []


def script_errors(marks, known):
    is_known = matcher(known)
    found = collections.Counter()
    for m in marks:
        if m.startswith("journal "):
            entry = json.loads(m[8:])
            message = entry.get("MESSAGE", "")
            if isinstance(message, list):
                message = bytes(message).decode(errors="replace")
            source = entry.get("_SYSTEMD_UNIT", "journal")
            if source == "rocknix-boot-test.service":
                continue
        elif m.startswith("boot.log "):
            source, message = "boot.log", m[9:]
        else:
            continue
        if SHELL_ERROR.search(message):
            line = f"{source}: {message}"
            if not is_known(line):
                found[line] += 1
    return found


def split_expected(items, xfail):
    is_expected = matcher(xfail)
    return [i for i in items if not is_expected(i)], [i for i in items if is_expected(i)]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--image", required=True)
    p.add_argument("--kernel", required=True)
    p.add_argument("--initrd", required=True)
    p.add_argument("--known", default="")
    p.add_argument("--errors", default="")
    p.add_argument("--log", default="/tmp/boot.log")
    p.add_argument("--display", action="store_true")
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--cpus", type=int, default=4)
    p.add_argument("--memory", type=int, default=2048)
    args = p.parse_args()

    args.work = tempfile.mkdtemp()
    args.screenshot = os.path.join(os.path.dirname(os.path.abspath(args.log)), "screen.png")
    disk = raw_disk(args.image, args.work)
    script = SETTLE + (DISPLAY if args.display else "") + REPORT
    files = {
        "/.config/system.d/rocknix-boot-test.service": UNIT,
        "/.rocknix-boot-test": f"ERRORS=\"{ERRORS}\"\n" + script,
    }
    if args.display:
        files.update(DISPLAY_FILES)
    prepare_storage(disk, args.work, files)
    lines, share, elapsed = boot(args, disk, args.log)

    known = set(known_lines(args.known))
    marks = [l.split("ROCKNIX-BOOT ", 1)[1] for l in lines if "ROCKNIX-BOOT " in l]
    failed = sorted({m.split(": ", 1)[1] for m in marks if m.startswith("failed: ")} - known)
    logs = {}
    for m in marks:
        if m.startswith("log "):
            unit, text = m[4:].split(": ", 1)
            logs.setdefault(unit, []).append("    " + text)
    errors = script_errors(marks, known_lines(args.errors))
    counted = lambda lines: "\n".join(l + (f" ({errors[l]}x)" if errors[l] > 1 else "") for l in lines)
    unit_logs = lambda units: "\n".join(u + ("\n" + "\n".join(logs.get(u, [])) if logs.get(u) else "") for u in units)
    new_units, expected_units = split_expected(failed, xfail_lines(args.known))
    new_errors, expected_errors = split_expected(sorted(errors), xfail_lines(args.errors))
    results = [
        ("systemd_started", any("systemd[1]" in l or "Welcome to" in l for l in lines), ""),
        ("boot_test_ran", "done" in marks, f"no result within {args.timeout}s, see {args.log}"),
        ("startup_settled", "jobs-left=0" in marks,
         "\n".join(m for m in marks if m.startswith(("jobs-left", "job: ")))),
        ("no_failed_units", "done" in marks and not new_units, unit_logs(new_units), unit_logs(expected_units)),
        ("no_script_errors", "done" in marks and not new_errors, counted(new_errors), counted(expected_errors)),
    ]
    if args.display:
        running = {m[9:] for m in marks if m.startswith("running: ")}
        connectors = [m[11:] for m in marks if m.startswith("connector: ")]
        es = "\n".join(m[4:] for m in marks if m.startswith("es: "))
        results += [
            ("display_compositor", bool(running & {"sway", "kwin_wayland"}), "no sway or kwin_wayland process"),
            ("display_output", any(c.endswith(" connected enabled") for c in connectors),
             "\n".join(connectors) or "no DRM connectors"),
            ("display_frontend", "emulationstation" in running, es or "emulationstation is not running"),
            ("display_screenshot", share is not None and share < 0.9,
             "no screendump" if share is None else f"{share:.0%} of the screen is one color, see {args.screenshot}"),
        ]
    status = 0
    for n, (name, ok, detail, *expected) in enumerate(results, 1):
        if ok and expected and expected[0]:
            print(f"not ok {n} - boot: {name} # TODO expected failure")
            detail = expected[0]
        else:
            print(f"{'ok' if ok else 'not ok'} {n} - boot: {name}")
            status |= not ok
        if not ok or (expected and expected[0]):
            for d in detail.splitlines():
                print(f"#   {d}")
    print(f"1..{len(results)}")
    print(f"# booted in {elapsed:.0f}s, serial log {args.log}")
    sys.exit(int(status))


if __name__ == "__main__":
    main()
