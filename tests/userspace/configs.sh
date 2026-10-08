# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

CONFIGS_KNOWN=${TESTS}/userspace/configs.known
CONFIG_DIRS="/usr/config /etc ${REPO}/projects/ROCKNIX"
CFG_CHECK=$(cat <<'EOF'
import json
import os
import re
import sys
import tomllib
import xml.etree.ElementTree as ET

RETROARCH_LINE = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_.+-]* = ("[^"]*"|[^\s"]+)$')
SYSTEM_CFG_LINE = re.compile(r"^([A-Za-z0-9][^=\s]*)=")
CWCHEAT_LINE = re.compile(r"^(_[SGL] |_C[0-9] |//)")
SECTION = re.compile(r"^\[[^\]]*\]\s*([;#].*)?$")
# Dolphin keeps patch and cheat code lines verbatim in these sections
RAW_SECTIONS = re.compile(r"^(OnFrame|ActionReplay|AR|Gecko|Patches|WC24Patch)(_Enabled|_Disabled|_RetroAchievements_Verified)?$")
SYSTEMD_DIRS = re.compile(r"^(systemd|(system|user|sleep|logind|journald|resolved|timesyncd|coredump|oomd|pstore)\.conf\.d)$")


def kind(path):
    name = os.path.basename(path)
    ext = os.path.splitext(name)[1].lower()
    if ext in (".json", ".toml", ".xml"):
        return ext[1:]
    if ext in (".yml", ".yaml"):
        return "yaml"
    if path.endswith("/system/configs/system.cfg"):
        return "systemcfg"
    if ext in (".opt", ".rmp") or (ext == ".cfg" and name.startswith("retroarch")):
        return "retroarch"
    if ext == ".ini":
        return "cwcheat" if "/PSP/Cheats/" in path else "ini"
    if ext in (".cfg", ".conf"):
        with open(path, "rb") as f:
            if f.read(64).lstrip(b"\xef\xbb\xbf \t\r\n").startswith(b"<"):
                return "xml"
        if ext == ".conf" and SYSTEMD_DIRS.match(os.path.basename(os.path.dirname(path))):
            return "ini"
    return None


def lines(path):
    with open(path, encoding="utf-8-sig", errors="surrogateescape") as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if s and s[0] not in "#;":
                yield n, s


def check_ini(path):
    section = None
    for n, s in lines(path):
        if s.startswith("["):
            if not SECTION.match(s):
                return f"line {n}: malformed section header: {s}"
            section = s[1:s.index("]")].strip()
        elif not s.split("=", 1)[0].strip() or "=" not in s:
            if section is None or not RAW_SECTIONS.match(section):
                return f"line {n}: not a [section] or key=value: {s}"
    return None


def check_lines(path, pattern):
    for n, s in lines(path):
        if not pattern.match(s):
            return f"line {n}: {s}"
    return None


def check_system_cfg(path):
    seen = {}
    for n, s in lines(path):
        m = SYSTEM_CFG_LINE.match(s)
        if not m:
            return f"line {n}: not key=value: {s}"
        if m.group(1) in seen:
            return f"line {n}: {m.group(1)} already set on line {seen[m.group(1)]}"
        seen[m.group(1)] = n
    return None


def check(path, k):
    try:
        if k == "json":
            with open(path, "rb") as f:
                json.loads(f.read().decode("utf-8-sig"))
        elif k == "toml":
            with open(path, "rb") as f:
                tomllib.load(f)
        elif k == "yaml":
            import yaml
            with open(path, "rb") as f:
                list(yaml.safe_load_all(f))
        elif k == "xml":
            ET.parse(path)
        elif k == "ini":
            return check_ini(path)
        elif k == "retroarch":
            return check_lines(path, RETROARCH_LINE)
        elif k == "cwcheat":
            return check_lines(path, CWCHEAT_LINE)
        elif k == "systemcfg":
            return check_system_cfg(path)
    except Exception as e:
        return (str(e).strip().splitlines() or [type(e).__name__])[0]
    return None


def main():
    want, known_file, repo, roots = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    with open(known_file) as f:
        known = {line.strip() for line in f if line.strip()}
    count = 0
    for top in roots:
        for dirpath, dirs, names in os.walk(top):
            dirs.sort()
            for name in sorted(names):
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not os.path.isfile(path) or kind(path) != want:
                    continue
                count += 1
                shown = os.path.relpath(path, repo) if path.startswith(repo + "/") else path
                err = check(path, want)
                if err and shown not in known:
                    print(f"{shown}: {err}")
    print(f"checked {count}")


main()
EOF
)

cfg_check() {
  (cd / && python3 -I -c "${CFG_CHECK}" "$1" "${2:-${CONFIGS_KNOWN}}" "${REPO}" ${3:-${CONFIG_DIRS}})
}

check_configs() {
  local out count
  out=$(cfg_check "$1") || fail "config check failed: ${out}"
  count=$(echo "${out}" | tail -n 1)
  out=$(echo "${out}" | sed '$d')
  [ "${count#checked }" -gt 0 ] || fail "no $1 files found in ${CONFIG_DIRS}"
  [ -z "${out}" ] || fail "$1 files that do not parse:"$'\n'"${out}"
}

put() {
  mkdir -p "$(dirname "$1")"
  printf "$2" >"$1"
}

test_checker_reports_broken_files() {
  local out
  put good/a.json '{"a": [1, 2]}\n'
  put bad/a.json '{"a": [1, 2],}\n'
  put good/a.xml '<?xml version="1.0"?>\n<a><b/></a>\n'
  put bad/a.xml '<a><b></a>\n'
  put good/es_systems.cfg '<?xml version="1.0"?>\n<systemList></systemList>\n'
  put bad/es_systems.cfg '<systemList>\n'
  put good/a.toml '[a]\nb = "c"\n'
  put bad/a.toml '[a]\nb = \n'
  put good/a.ini '; c\n[Core]\nKey = Value\n[Gecko]\n$Code\n0400 0001\n'
  put bad/a.ini '[Core]\nKey Value\n'
  put bad/b.ini '[Core\nKey = Value\n'
  put good/sleep.conf.d/a.conf '[Sleep]\nAllowSuspend=yes\n'
  put bad/sleep.conf.d/a.conf 'AllowSuspend\n'
  put good/retroarch/retroarch.cfg '# c\nvideo_driver = "gl"\n\ninput_x = ""\n'
  put bad/retroarch/retroarch.cfg 'video_driver = "gl\n'
  put bad/retroarch/Core.opt 'core_opt = "a"\ncore_opt2 "b"\n'
  put good/system/configs/system.cfg '# c\naudio.volume=50\nwifi.ssid=My Net\n'
  put bad/system/configs/system.cfg 'audio.volume=50\naudio volume\n'
  put bad/dup/system/configs/system.cfg 'a.b=1\na.b=2\n'
  put good/PSP/Cheats/ULES00001.ini '_S ULES-00001\n_G Game\n_C0 Cheat\n_L 0x1 0x2\n'
  put bad/PSP/Cheats/ULES00001.ini 'ULES-00001\n_G Game\n'
  out=$(for k in json xml toml ini retroarch systemcfg cwcheat; do echo "${k} $(cfg_check ${k} /dev/null "${PWD}/good")"; done)
  assert_eq "${out}" "$(printf '%s\n' 'json checked 1' 'xml checked 2' 'toml checked 1' 'ini checked 2' \
    'retroarch checked 1' 'systemcfg checked 1' 'cwcheat checked 1')" "valid files"
  out=$(for k in json xml toml ini retroarch systemcfg cwcheat; do cfg_check ${k} /dev/null "${PWD}/bad"; done |
    grep -v '^checked' | cut -d: -f1 | sed "s|^${PWD}/||" | sort)
  assert_eq "${out}" "$(printf '%s\n' bad/PSP/Cheats/ULES00001.ini bad/a.json bad/a.ini bad/a.toml bad/a.xml bad/b.ini \
    bad/dup/system/configs/system.cfg bad/es_systems.cfg bad/retroarch/Core.opt bad/retroarch/retroarch.cfg \
    bad/sleep.conf.d/a.conf bad/system/configs/system.cfg | sort)" "broken files"
  echo "${PWD}/bad/a.json" >known
  assert_eq "$(cfg_check json "${PWD}/known" "${PWD}/bad")" "checked 1" "known file"
}

test_json_configs_parse() {
  check_configs json
}

test_xml_configs_parse() {
  check_configs xml
}

test_toml_configs_parse() {
  check_configs toml
}

test_yaml_configs_parse() {
  python3 -c 'import yaml' 2>/dev/null || skip "no PyYAML in this image"
  check_configs yaml
}

test_ini_configs_parse() {
  check_configs ini
}

test_retroarch_configs_parse() {
  check_configs retroarch
}

test_cwcheat_files_parse() {
  check_configs cwcheat
}

test_system_cfg_parses() {
  check_configs systemcfg
}

test_profile_fragments_parse() {
  local f out errors="" n=0
  while IFS= read -r -d '' f; do
    n=$((n + 1))
    out=$(bash -n "${f}" 2>&1) || errors="${errors}${out:-${f}: parse failed}"$'\n'
  done < <(find /etc/profile.d "${REPO}/projects/ROCKNIX" -path '*/profile.d/*' -type f -print0)
  [ ${n} -gt 10 ] || fail "only ${n} profile.d fragments found"
  errors=${errors//"${REPO}/"/}
  [ -z "${errors}" ] || fail "profile.d fragments that do not parse:"$'\n'"${errors%$'\n'}"
}

test_config_scripts_parse() {
  local f sh out errors="" n=0
  while IFS= read -r -d '' f; do
    case "$(head -n 1 "${f}")" in
      '#!'*bash*) sh=bash ;;
      *) sh=/bin/sh ;;
    esac
    n=$((n + 1))
    out=$(${sh} -n "${f}" 2>&1) || errors="${errors}${out:-${f}: parse failed}"$'\n'
  done < <(find /usr/config "${REPO}/projects/ROCKNIX/packages/misc/modules/sources" -name '*.sh' -type f -print0)
  [ ${n} -gt 10 ] || fail "only ${n} scripts found"
  errors=${errors//"${REPO}/"/}
  [ -z "${errors}" ] || fail "shell scripts for /usr/config that do not parse:"$'\n'"${errors%$'\n'}"
}
