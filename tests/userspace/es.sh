# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

ES_SYSTEMS=/usr/config/emulationstation/es_systems.cfg
ES_FEATURES=${REPO}/projects/ROCKNIX/packages/ui/emulationstation/config/common/es_features.cfg
EMULATORS_MK=${REPO}/projects/ROCKNIX/packages/virtual/emulators/package.mk
ROCKNIX_PKG=${REPO}/projects/ROCKNIX/packages/rocknix
ES_KNOWN=${TESTS}/userspace/es.known

es_known() {
  . /etc/os-release
  known_failure "${ES_KNOWN}" "$1" || known_failure "${ES_KNOWN}" "${HW_DEVICE} $1" ||
    known_failure "${ES_KNOWN}" "${HW_DEVICE}-${OS_VERSION} $1"
}

es_cores() {
  python3 - "${ES_SYSTEMS}" "$1" <<'EOF'
import sys, xml.etree.ElementTree as ET
for s in ET.parse(sys.argv[1]).getroot().iter("system"):
    exts = [e for e in (s.findtext("extension") or "").split() if e.lower() != ".sh"]
    if not exts:
        continue
    for e in s.iter("emulator"):
        if (e.get("name") == "retroarch") != (sys.argv[2] == "retroarch"):
            continue
        for c in e.iter("core"):
            print("\t".join((s.findtext("name"), e.get("name"), c.text or "", s.findtext("path"), exts[0])))
EOF
}

runemu_env() {
  local f launchers
  launchers="/usr/bin/retroarch /usr/bin/retroarch32 $(echo /usr/bin/start_*.sh)"
  STUBBED="/usr/bin/setsettings.sh /usr/bin/game-guides-tool ${launchers}"
  trap runemu_cleanup EXIT
  mv /etc/profile.d/001-functions /run/es-001-functions
  cp "${ROCKNIX_PKG}/profile.d/001-functions" /etc/profile.d/001-functions
  mkdir -p /storage/.config/system/configs /storage/.config/profile.d /storage/.config/PortMaster /var/log
  cp "${ROCKNIX_PKG}/config/system/configs/system.cfg" /storage/.config/system/configs/system.cfg
  printf '%s\n' "set_cpu_gov() { :; }" "set_dmc_gov() { :; }" "set_gpu_gov() { :; }" "set_online_threads() { :; }" \
    >/storage/.config/profile.d/zz-es-test
  printf '%s\n' ACTIVE_GAME= ACTIVE_PLATFORM= >/storage/.config/PortMaster/mapper.txt
  printf '#!/bin/sh\n' | stub /usr/bin/setsettings.sh
  printf '#!/bin/sh\n' | stub /usr/bin/game-guides-tool
  for f in ${launchers}; do
    stub "${f}" <<'EOF'
#!/bin/bash
printf '%s\n' "$0" "$@" >/tmp/es.ran
EOF
  done
}

runemu_cleanup() {
  unstub ${STUBBED}
  [ -e /run/es-001-functions ] && mv -f /run/es-001-functions /etc/profile.d/001-functions
  rm -rf /storage/.config /storage/roms /tmp/es.* /tmp/.retroarch.cfg /tmp/.process-kill-data /tmp/.system.cfg.lock \
    /tmp/launch_error.log /tmp/shader /var/log/exec.log /run/rocknix
  return 0
}

es_launch() {
  local system=$1 emulator=$2 core=$3 rom="$4/My Games/Test Game (USA)$5"
  mkdir -p "${rom%/*}"
  printf '#!/bin/bash\nprintf "%%s\\n" "$0" "$@" >/tmp/es.ran\n' >"${rom}"
  rm -f /tmp/es.ran /var/log/exec.log
  bash "${ROCKNIX_PKG}/sources/scripts/runemu.sh" "${rom}" -P"${system}" --core="${core}" --emulator="${emulator}" \
    --controllers=" -p1index 0 -p1guid 19000000010000000100000000010000 " >/dev/null 2>&1
  [ -s /tmp/es.ran ] && return 0
  echo "nothing launched: $(grep -v '^$' /var/log/exec.log 2>/dev/null | tail -n 1)"
  return 1
}

elf_bits() {
  [ "$(head -c 4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = "177ELF" ] || return 1
  echo $(( $(od -An -tu1 -j4 -N1 "$1") * 32 ))
}

test_es_systems_parse_with_unique_names() {
  local out
  out=$(python3 - "${ES_SYSTEMS}" <<'EOF' 2>&1
import sys, xml.etree.ElementTree as ET
systems = set()
for s in ET.parse(sys.argv[1]).getroot().iter("system"):
    name = s.findtext("name")
    for field in ("name", "fullname", "path", "extension", "command", "platform", "theme"):
        if not (s.findtext(field) or "").strip():
            print(f"{name}: no {field}")
    if name in systems:
        print(f"{name}: duplicate system")
    systems.add(name)
    emulators = set()
    for e in s.iter("emulator"):
        if e.get("name") in emulators:
            print(f"{name}: duplicate emulator {e.get('name')}")
        emulators.add(e.get("name"))
        cores = [c.text for c in e.iter("core")]
        if not cores:
            print(f"{name}: emulator {e.get('name')} has no cores")
        for c in sorted(set(c for c in cores if cores.count(c) > 1)):
            print(f"{name}: duplicate core {e.get('name')}/{c}")
if not systems:
    print("no systems")
EOF
)
  [ -z "${out}" ] || fail "${ES_SYSTEMS}:"$'\n'"${out}"
}

test_es_systems_one_default_core() {
  local out
  out=$(python3 - "${ES_SYSTEMS}" <<'EOF' 2>&1
import sys, xml.etree.ElementTree as ET
for s in ET.parse(sys.argv[1]).getroot().iter("system"):
    cores = list(s.iter("core"))
    defaults = [c.text for c in cores if c.get("default") == "true"]
    if cores and len(defaults) != 1:
        print(f"{s.findtext('name')}: default cores {defaults}")
EOF
)
  [ -z "${out}" ] || fail "systems without exactly one default core:"$'\n'"${out}"
}

test_es_systems_commands_exist() {
  local cmd failures=""
  [ -f "${ROCKNIX_PKG}/sources/scripts/runemu.sh" ] || fail "runemu.sh not in the tree"
  while read -r cmd; do
    case "${cmd}" in
      /*) [ -x "${cmd}" ] || failures="${failures}${cmd}"$'\n' ;;
      *) failures="${failures}${cmd} (not an absolute path)"$'\n' ;;
    esac
  done < <(python3 - "${ES_SYSTEMS}" <<'EOF'
import sys, xml.etree.ElementTree as ET
print("\n".join(sorted({(s.findtext("command") or "").split()[0] for s in ET.parse(sys.argv[1]).getroot().iter("system")})))
EOF
)
  [ -z "${failures}" ] || fail "launch commands not in the image:"$'\n'"${failures}"
}

test_es_systems_retroarch_cores_load() {
  local system emulator core path ext out bin so want have failures=""
  runemu_env
  while IFS="$(printf '\t')" read -r system emulator core path ext; do
    es_known "${emulator} ${core}" && continue
    if ! out=$(es_launch "${system}" "${emulator}" "${core}" "${path}" "${ext}"); then
      failures="${failures}${system} ${core}: ${out}"$'\n'
      continue
    fi
    bin=$(head -n 1 /tmp/es.ran)
    case "${bin}" in /usr/bin/retroarch|/usr/bin/retroarch32) ;; *) continue ;; esac
    so=$(sed -n '/^-L$/{n;p;q}' /tmp/es.ran)
    so=/usr/lib/libretro/${so#/tmp/cores/}
    want=$(elf_bits "${STUBS}/orig${bin}")
    have=$(elf_bits "${so}") || { failures="${failures}${system} ${core}: ${so} missing"$'\n'; continue; }
    [ "${have}" = "${want}" ] || failures="${failures}${system} ${core}: ${so} is ${have}-bit, ${bin} is ${want}-bit"$'\n'
  done < <(es_cores retroarch)
  [ -z "${failures}" ] || fail "RetroArch cores that do not load:"$'\n'"${failures}"
}

test_es_systems_standalone_emulators_launch() {
  local system emulator core path ext out failures=""
  runemu_env
  while IFS="$(printf '\t')" read -r system emulator core path ext; do
    es_known "${emulator} ${core}" && continue
    out=$(es_launch "${system}" "${emulator}" "${core}" "${path}" "${ext}") ||
      failures="${failures}${system} ${emulator}/${core}: ${out}"$'\n'
  done < <(es_cores standalone)
  [ -z "${failures}" ] || fail "standalone emulators runemu.sh cannot start:"$'\n'"${failures}"
}

test_es_features_refer_to_known_cores() {
  local out
  out=$(python3 - "${ES_FEATURES}" "${EMULATORS_MK}" <<'EOF' 2>&1
import re, sys, xml.etree.ElementTree as ET
pairs = set(re.findall(r"^\s*add_emu_core\s+\S+\s+(\S+)\s+(\S+)\s+(?:true|false)\s*$", open(sys.argv[2]).read(), re.M))
emulators = {e for e, _ in pairs}
for e in ET.parse(sys.argv[1]).getroot().iter("emulator"):
    name = e.get("name")
    if name not in emulators:
        print(f"emulator {name}")
    cores = [c.get("name") for c in e.iter("core")]
    for c in sorted(set(cores)):
        if (name, c) not in pairs:
            print(f"core {name}/{c}")
        if cores.count(c) > 1:
            print(f"duplicate core {name}/{c}")
EOF
)
  out=$(echo "${out}" | while read -r line; do [ -n "${line}" ] && ! es_known "features ${line}" && echo "${line}"; done)
  [ -z "${out}" ] || fail "es_features.cfg entries no system in virtual/emulators uses:"$'\n'"${out}"
}
