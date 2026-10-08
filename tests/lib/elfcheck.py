#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

import mmap
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

MACHINES = {32: 40, 64: 183}
RTLD = {32: "/usr/lib/ld-linux-armhf.so.3", 64: "/usr/lib/ld-linux-aarch64.so.1"}
SYSTEM_DIRS = ["/usr/lib"]
SKIP_DIRS = {"/usr/lib/modules", "/usr/lib/firmware", "/usr/lib/kernel-overlays"}
DT_NEEDED, DT_STRTAB, DT_SONAME, DT_RPATH, DT_RUNPATH = 1, 5, 14, 15, 29
DT_FLAGS_1, DT_VERDEF, DT_VERDEFNUM, DT_VERNEED, DT_VERNEEDNUM = (0x6FFFFFFB, 0x6FFFFFFC, 0x6FFFFFFD,
                                                                  0x6FFFFFFE, 0x6FFFFFFF)
DF_1_NODEFLIB = 0x800
VER_FLG_WEAK = 2


class Elf:
    def __init__(self, bits, interp, needed, soname, rpath, runpath, nodeflib, verneed, verdef):
        self.bits = bits
        self.interp = interp
        self.needed = needed
        self.soname = soname
        self.rpath = rpath
        self.runpath = runpath
        self.nodeflib = nodeflib
        self.verneed = verneed
        self.verdef = verdef


def parse_elf(data, bits):
    if bits == 64:
        e_type, e_machine, _, _, e_phoff = struct.unpack_from("<HHIQQ", data, 16)
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    else:
        e_type, e_machine, _, _, e_phoff = struct.unpack_from("<HHIII", data, 16)
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 42)
    if e_type not in (2, 3) or e_machine != MACHINES[bits]:
        return None
    loads, dynamic, interp = [], None, None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if bits == 64:
            p_type, _, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIQQQQ", data, off)
        else:
            p_type, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIIII", data, off)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dynamic = (p_offset, p_filesz)
        elif p_type == 3:
            interp = data[p_offset:p_offset + p_filesz].split(b"\0")[0].decode(errors="replace")
    if dynamic is None:
        return None

    def offset(addr):
        for vaddr, off, size in loads:
            if vaddr <= addr < vaddr + size:
                return addr - vaddr + off
        raise ValueError("address outside PT_LOAD")

    dyn_fmt = "<qQ" if bits == 64 else "<iI"
    step = struct.calcsize(dyn_fmt)
    tags = {}
    for pos in range(dynamic[0], dynamic[0] + dynamic[1] - step + 1, step):
        tag, val = struct.unpack_from(dyn_fmt, data, pos)
        if tag == 0:
            break
        tags.setdefault(tag, []).append(val)
    strtab = offset(tags[DT_STRTAB][0])

    def string(index):
        start = strtab + index
        return data[start:data.find(b"\0", start)].decode(errors="replace")

    def paths(tag):
        return [d for v in tags.get(tag, []) for d in string(v).split(":") if d]

    verneed = {}
    if DT_VERNEED in tags:
        pos = offset(tags[DT_VERNEED][0])
        for _ in range(tags.get(DT_VERNEEDNUM, [1 << 16])[0]):
            _, vn_cnt, vn_file, vn_aux, vn_next = struct.unpack_from("<HHIII", data, pos)
            versions = verneed.setdefault(string(vn_file), [])
            aux = pos + vn_aux
            for _ in range(vn_cnt):
                _, vna_flags, _, vna_name, vna_next = struct.unpack_from("<IHHII", data, aux)
                if not vna_flags & VER_FLG_WEAK:
                    versions.append(string(vna_name))
                aux += vna_next
            if not vn_next:
                break
            pos += vn_next
    verdef = None
    if DT_VERDEF in tags:
        verdef = set()
        pos = offset(tags[DT_VERDEF][0])
        for _ in range(tags.get(DT_VERDEFNUM, [1 << 16])[0]):
            _, _, _, vd_cnt, _, vd_aux, vd_next = struct.unpack_from("<HHHHIII", data, pos)
            if vd_cnt:
                verdef.add(string(struct.unpack_from("<I", data, pos + vd_aux)[0]))
            if not vd_next:
                break
            pos += vd_next
    return Elf(bits, interp, [string(v) for v in tags.get(DT_NEEDED, [])],
               string(tags[DT_SONAME][0]) if DT_SONAME in tags else None, paths(DT_RPATH),
               paths(DT_RUNPATH) if DT_RUNPATH in tags else None,
               bool(tags.get(DT_FLAGS_1, [0])[0] & DF_1_NODEFLIB), verneed, verdef)


def read_elf(path):
    try:
        with open(path, "rb") as f:
            head = f.read(64)
            if len(head) < 52 or head[:4] != b"\x7fELF" or head[5] != 1 or head[4] not in (1, 2):
                return None
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    except (OSError, ValueError):
        return None
    try:
        return parse_elf(data, 32 * head[4])
    except (struct.error, ValueError, KeyError, IndexError):
        return None
    finally:
        data.close()


def ld_cache():
    tmp = tempfile.mkdtemp()
    cache = os.path.join(tmp, "ld.so.cache")
    try:
        subprocess.run(["ldconfig", "-X", "-C", cache], capture_output=True, timeout=300)
        out = subprocess.run(["ldconfig", "-p", "-C", cache], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    entries = {}
    for line in out.splitlines():
        m = re.match(r"\s+(\S+) \(([^)]*)\) => (\S+)$", line)
        if m:
            bits = 64 if "AArch64" in m.group(2) else 32 if "hard-float" in m.group(2) else None
            if bits:
                entries.setdefault((bits, m.group(1)), m.group(3))
    return entries


class Loaded:
    def __init__(self, path, obj, loader, origin, name=None):
        self.path = path
        self.real = os.path.realpath(path)
        self.obj = obj
        self.loader = loader
        self.origin = origin
        self.name = name
        self.names = {path}


class Image:
    def __init__(self, library_path=()):
        self.objects = {}
        self.lookups = {}
        self.cache = ld_cache()
        self.library_path = library_path

    def load(self, path):
        real = os.path.realpath(path)
        if real not in self.objects:
            self.objects[real] = read_elf(real) if os.path.isfile(real) else None
        return self.objects[real]

    def find(self, name, dirs, bits):
        key = (name, tuple(dirs), bits)
        if key not in self.lookups:
            self.lookups[key] = None
            for d in dirs:
                path = os.path.join(d, name)
                obj = self.load(path)
                if obj is not None and obj.bits == bits:
                    self.lookups[key] = path
                    break
        return self.lookups[key]

    def search(self, name, loader, main, library_path):
        bits = loader.obj.bits
        if "/" in name:
            obj = self.load(name)
            return name if obj is not None and obj.bits == bits else None

        def expand(entry, dirs):
            return [d.replace("${ORIGIN}", entry.origin).replace("$ORIGIN", entry.origin) for d in dirs]

        if loader.obj.runpath is None:
            done_main, entry = False, loader
            while entry is not None:
                found = entry.obj.rpath and self.find(name, expand(entry, entry.obj.rpath), bits)
                if found:
                    return found
                done_main |= entry is main
                entry = entry.loader
            found = not done_main and main.obj.rpath and self.find(name, expand(main, main.obj.rpath), bits)
            if found:
                return found
        found = library_path and self.find(name, library_path, bits)
        if found:
            return found
        found = loader.obj.runpath and self.find(name, expand(loader, loader.obj.runpath), bits)
        if found:
            return found
        if loader.obj.nodeflib:
            return None
        cached = self.cache.get((bits, name))
        if cached and self.find(os.path.basename(cached), [os.path.dirname(cached)], bits):
            return cached
        return self.find(name, SYSTEM_DIRS, bits)

    def simulate(self, path, obj):
        main = Loaded(path, obj, None, os.path.dirname(os.path.realpath(path)))
        loaded = [main]
        rtld = obj.interp or RTLD[obj.bits]
        rtld_obj = self.load(rtld)
        if rtld_obj is not None and rtld_obj.bits == obj.bits and os.path.realpath(rtld) != main.real:
            loaded.append(Loaded(rtld, rtld_obj, None, os.path.dirname(rtld)))
        by_real = {e.real: e for e in loaded}
        library_path = [d for d in self.library_path if main.real.startswith(d.rstrip("/") + "/")]

        def match(name):
            for e in loaded:
                if name in e.names or name == e.obj.soname:
                    return e
            return None

        bound = []
        for entry in loaded:
            if entry is not main and entry.loader is None:
                continue
            for name in entry.obj.needed:
                dep = match(name)
                if dep is None:
                    found = self.search(name, entry, main, library_path)
                    if found:
                        real = os.path.realpath(found)
                        dep = by_real.get(real)
                        if dep is None:
                            dep = by_real[real] = Loaded(found, self.objects[real], entry, os.path.dirname(found), name)
                            loaded.append(dep)
                        dep.names.add(name)
                bound.append((entry, name, dep))
        versions = []
        for entry in loaded:
            if entry is not main and entry.loader is None:
                continue
            for name, needs in entry.obj.verneed.items():
                dep = match(name)
                if dep is not None:
                    verdef = dep.obj.verdef
                    versions.extend((entry, name, ver, None if verdef is None else ver in verdef) for ver in needs)
        return loaded, bound, versions


def scan(paths):
    for top in paths:
        for dirpath, dirs, files in os.walk(top):
            dirs[:] = sorted(d for d in dirs if os.path.join(dirpath, d) not in SKIP_DIRS)
            for name in sorted(files):
                path = os.path.join(dirpath, name)
                if not name.endswith(".ko") and not os.path.islink(path):
                    yield path


def check(image, paths, classes, versions):
    files = {}
    for path in scan(paths):
        obj = image.load(path)
        if obj is not None and obj.bits in classes:
            files[os.path.realpath(path)] = obj
    resolved, good, bad, simulated, covered = set(), set(), {}, set(), set()

    def run(real, obj):
        simulated.add(real)
        loaded, bound, vers = image.simulate(real, obj)
        covered.update(e.real for e in loaded)
        resolved.update((e.real, name) for e, name, dep in bound if dep is not None)
        for e, name, ver, ok in vers:
            if ok:
                good.add((e.real, name, ver))
            else:
                bad.setdefault((e.real, name, ver), ok)

    def failing(real, obj):
        return (any((real, n) not in resolved for n in obj.needed) or
                any((real, n, v) in bad and (real, n, v) not in good for n, vs in obj.verneed.items() for v in vs))

    for real, obj in files.items():
        if obj.interp:
            run(real, obj)
    for real, obj in files.items():
        if real not in simulated and (real not in covered or failing(real, obj)):
            run(real, obj)
    problems = {}
    for real, obj in sorted(files.items()):
        missing = [n for n in obj.needed if (real, n) not in resolved]
        if not versions:
            problems.update((f"{real} {n}", f"{real}: missing {n}") for n in missing)
            continue
        for name, needs in obj.verneed.items():
            for ver in needs:
                key = (real, name, ver)
                if name not in missing and key in bad and key not in good:
                    note = " (library has no version definitions)" if bad[key] is None else ""
                    problems[f"{real} {name} {ver}"] = f"{real}: {name} lacks {ver}{note}"
    return problems


def trace(image, path):
    obj = image.load(path)
    if obj is None:
        return set()
    loaded, bound, versions = image.simulate(path, obj)
    lines = {f"{e.name} => {e.path}" for e in loaded if e.name}
    lines.update(f"{name} => not found" for _, name, dep in bound if dep is None)
    lines.update(f"{e.path}: {name} lacks {ver}" for e, name, ver, ok in versions if ok is False)
    return lines


def ldso_trace(path, interp):
    env = {k: v for k, v in os.environ.items() if not k.startswith("LD_")}
    env.update(LD_TRACE_LOADED_OBJECTS="1", LD_WARN="yes")
    proc = subprocess.run([RTLD[64], path], capture_output=True, text=True, env=env, timeout=60)
    lines = set()
    for line in proc.stdout.splitlines():
        name, arrow, target = line.strip().partition(" => ")
        if arrow and name != interp:
            lines.add(f"{name} => {target.rsplit(' (0x', 1)[0]}")
    for line in proc.stderr.splitlines():
        m = re.search(r": ([^:]+): version `([^']+)' not found \(required by (.+)\)$", line)
        if m:
            lines.add(f"{m.group(3)}: {os.path.basename(m.group(1))} lacks {m.group(2)}")
    return lines


def native(image, paths, executables):
    rtld = os.path.realpath(RTLD[64])
    for path in scan(paths):
        obj = image.load(path)
        if obj is None or obj.bits != 64 or (obj.interp and os.path.realpath(obj.interp) != rtld):
            continue
        if not executables or obj.interp:
            yield path, obj


def compare(image, paths):
    for path, obj in native(image, paths, False):
        mine, real = trace(image, path), ldso_trace(path, obj.interp)
        for line in sorted(mine - real):
            yield f"{path}: checker only: {line}"
        for line in sorted(real - mine):
            yield f"{path}: ld.so only: {line}"


def undefined(image, paths):
    env = {k: v for k, v in os.environ.items() if not k.startswith("LD_")}
    env.update(LD_TRACE_LOADED_OBJECTS="1", LD_WARN="yes", LD_BIND_NOW="1")
    for path, _ in native(image, paths, True):
        proc = subprocess.run([RTLD[64], path], capture_output=True, text=True, env=env, timeout=60)
        if "=> not found" in proc.stdout:
            continue
        for line in proc.stderr.splitlines():
            m = re.match(r"undefined symbol: (.+?)\s+\((.+)\)$", line.strip())
            if m:
                yield f"{path} {m.group(1)}", f"{path}: undefined symbol {m.group(1)} in {m.group(2)}"


def main():
    args = sys.argv[1:]
    classes, versions, known, mode, library_path = set(), False, set(), "check", []
    while args and args[0].startswith("--"):
        opt = args.pop(0)
        if opt == "--bits":
            classes.add(int(args.pop(0)))
        elif opt == "--versions":
            versions = True
        elif opt == "--ld-library-path":
            library_path.append(args.pop(0))
        elif opt == "--known":
            with open(args.pop(0)) as f:
                known = {" ".join(line.split()) for line in f if line.strip()}
        elif opt in ("--compare-ld-so", "--trace", "--undefined"):
            mode = opt[2:]
    image = Image(library_path)
    if mode == "compare-ld-so":
        lines = list(compare(image, args))
    elif mode == "trace":
        lines = [f"{path}: {line}" for path in args for line in sorted(trace(image, path))]
    else:
        found = undefined(image, args) if mode == "undefined" else check(image, args, classes or {32, 64},
                                                                          versions).items()
        lines = [line for key, line in found if key not in known]
    if lines:
        print("\n".join(lines))


if __name__ == "__main__":
    main()
