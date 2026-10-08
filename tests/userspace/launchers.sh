# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PKGS=${REPO}/projects/ROCKNIX/packages
ROCKNIX_PKG=${PKGS}/rocknix
ES_SYSTEMS=/usr/config/emulationstation/es_systems.cfg
LAUNCHERS_KNOWN=${TESTS}/userspace/launchers.known
PROFILES="001-functions 099-freqfunctions 100-gamecontroller-functions 101-gpu-functions"
KEEP=" bash sh busybox python python3 python3.14 jq xml xmlstarlet grep sort gzip 7z 7za 7zr zip stdbuf timeout
  taskset chrt file strings readelf getconf iconv envsubst sqlite3 "
HELPERS="gptokeyb|swaymsg|systemctl|pactl|wpctl|wlr-randr|amixer|udevadm|mako-notify|text_viewer|sdljoytest|timedatectl"

launchers_known() {
  . /etc/os-release
  known_failure "${LAUNCHERS_KNOWN}" "$1" || known_failure "${LAUNCHERS_KNOWN}" "${HW_DEVICE} $1" ||
    known_failure "${LAUNCHERS_KNOWN}" "${HW_DEVICE}-${OS_VERSION} $1"
}

repo_script() {
  case "$1" in
    start_x128.sh|start_x64sc.sh|start_xplus4.sh|start_xvic.sh)
      echo "${PKGS}/emulators/standalone/vice-sa/scripts/start_vice.sh" ;;
    *) find "${PKGS}" -name "$1" \( -path '*/scripts/*' -o -path '*/sources/*' \) | head -n 1 ;;
  esac
}

built_script() {
  python3 - "$1" "$2" <<'EOF'
import difflib, re, sys
placeholder = re.compile(r"@([A-Z_]+)@")
repo = open(sys.argv[1]).read().split("\n")
built = open(sys.argv[2]).read().split("\n")
values = {}
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, repo, built, autojunk=False).get_opcodes():
    if tag != "replace" or i2 - i1 != j2 - j1:
        continue
    for line, done in zip(repo[i1:i2], built[j1:j2]):
        parts = placeholder.split(line)
        if len(parts) == 1:
            continue
        pattern = "".join(re.escape(p) if i % 2 == 0 else "(.*)" for i, p in enumerate(parts))
        m = re.fullmatch(pattern, done)
        if m:
            values.update(zip(parts[1::2], m.groups()))
text = "\n".join(repo)
in_built = "\n".join(built)
text = placeholder.sub(lambda m: values.get(m.group(1), m.group(0) if m.group(0) in in_built else ""), text)
first, _, rest = text.partition("\n")
prefix = '[ -e /tmp/launch.argv ] || printf "%s\\n" "$0" "$@" >/tmp/launch.argv; exec 2>>/tmp/launch.err'
print(f"{first}\n{prefix}\n{rest}" if first.startswith("#!") else f"{prefix}\n{text}")
EOF
}

script_paths() {
  local word
  grep -ohE '[A-Za-z0-9_./+-]+' "$@" | sort -u | while read -r word; do
    case "${word%/}" in
      /usr/lib*|/proc/*|/sys/*|/dev/*|/storage/*|/tmp/*|/run/*|*/bin|*/sbin) ;;
      /*/*/*) [ -d "${word}" ] && find "${word}" -maxdepth 1 -type f || echo "${word}" ;;
      /*) echo "${word}" ;;
      */*|.*|-*) ;;
      *) command -v "${word}" ;;
    esac
  done
}

referenced_elfs() {
  local path real
  script_paths "$@" | sort -u | while read -r path; do
    case "${path}" in /usr/bin/start_*.sh|*.so|*.so.*|[!/]*) continue ;; esac
    real=$(readlink -f "${path}") && [ -f "${real}" ] && [ -x "${real}" ] || continue
    case "${real}" in */busybox) continue ;; esac
    case "${KEEP}" in *" ${path##*/} "*|*" ${real##*/} "*) continue ;; esac
    [ "$(head -c 4 "${real}" | od -An -c | tr -d ' ')" = "177ELF" ] && echo "${path}"
  done
}

launch_env() {
  local f src elfs
  STUBBED="/usr/bin/setsettings.sh /usr/bin/game-guides-tool"
  LAUNCHERS=""
  trap launch_cleanup EXIT
  mkdir -p /run/launchers-profile /tmp/launchers /storage/.config/system/configs /storage/.config/profile.d \
    /storage/.config/PortMaster /var/log
  for f in ${PROFILES}; do
    [ -e "/etc/profile.d/${f}" ] && [ -e "${ROCKNIX_PKG}/profile.d/${f}" ] || continue
    mv "/etc/profile.d/${f}" /run/launchers-profile/
    cp "${ROCKNIX_PKG}/profile.d/${f}" "/etc/profile.d/${f}"
  done
  cp "${ROCKNIX_PKG}/config/system/configs/system.cfg" /storage/.config/system/configs/system.cfg
  printf '%s\n' "set_cpu_gov() { :; }" "set_dmc_gov() { :; }" "set_gpu_gov() { :; }" "set_online_threads() { :; }" \
    >/storage/.config/profile.d/zz-launchers-test
  printf '%s\n' ACTIVE_GAME= ACTIVE_PLATFORM= >/storage/.config/PortMaster/mapper.txt
  printf '#!/bin/sh\n' | stub /usr/bin/setsettings.sh
  printf '#!/bin/sh\n' | stub /usr/bin/game-guides-tool
  for f in /usr/bin/start_*.sh; do
    [ $# -eq 0 ] || [[ " $* " == *" ${f##*/} "* ]] || continue
    src=$(repo_script "${f##*/}")
    [ -n "${src}" ] || continue
    built_script "${src}" "${f}" >"/tmp/launchers/${f##*/}"
    LAUNCHERS="${LAUNCHERS} ${f}"
  done
  elfs=$(referenced_elfs /tmp/launchers/*)
  for f in ${LAUNCHERS}; do
    stub "${f}" <"/tmp/launchers/${f##*/}"
  done
  for f in ${elfs} /usr/bin/gptokeyb; do
    stub "${f}" <<'EOF'
#!/bin/bash
line=$0
for a; do
  line+=" [${a}]"
  [ -n "${LAUNCH_ROM}" ] && [ -f "${a}" ] && grep -qF "${LAUNCH_ROM}" "${a}" 2>/dev/null && line+=" [${LAUNCH_ROM}]"
done
printf '%s\n' "${line}" >>/tmp/launch.calls
[ "${0##*/}" = gptokeyb ] && { sleep 10 & wait; }
exit 0
EOF
  done
  stub /usr/bin/control-gen <<'EOF'
#!/bin/sh
cat <<'INI'
controlfolder="/storage/.config/gptokeyb"
ESUDO="sudo"
ESUDOKILL="-sudokill"
export SDL_GAMECONTROLLERCONFIG_FILE="$controlfolder/gamecontrollerdb.txt"
SDLDBFILE="${SDL_GAMECONTROLLERCONFIG_FILE}"
[ -z "${SDLDBFILE}" ] && SDLDBFILE="${controlfolder}/gamecontrollerdb.txt"
SDLDBUSERFILE="/storage/.config/SDL-GameControllerDB/gamecontrollerdb.txt"
get_controls() {
ANALOGSTICKS="2"
DEVICE="19000000010000000100000000010000"
param_device="Test Pad"
}
GPTOKEYB="$controlfolder/gptokeyb $ESUDOKILL"
INI
EOF
  stub /usr/sbin/fbset <<'EOF'
#!/bin/sh
printf 'mode "1920x1080-60"\n\tgeometry 1920 1080 1920 1080 32\nendmode\n'
EOF
  stub /usr/bin/nice <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -n) shift 2 ;;
    -n*|-[0-9]*|--adjustment=*) shift ;;
    *) break ;;
  esac
done
exec "$@"
EOF
  STUBBED="${STUBBED} ${LAUNCHERS} ${elfs} /usr/bin/gptokeyb /usr/bin/control-gen /usr/sbin/fbset /usr/bin/nice"
}

launch_cleanup() {
  local f
  unstub ${STUBBED}
  for f in /run/launchers-profile/*; do
    [ -e "${f}" ] && mv -f "${f}" "/etc/profile.d/${f##*/}"
  done
  rm -rf /storage/.config /storage/.local /storage/roms /tmp/launch.* /tmp/launchers /tmp/.retroarch.cfg \
    /tmp/.process-kill-data /tmp/.system.cfg.lock /tmp/launch_error.log /tmp/shader /var/log/exec.log /run/rocknix \
    /run/launchers-profile
  return 0
}

standalone_cores() {
  python3 - "${ES_SYSTEMS}" <<'EOF'
import sys, xml.etree.ElementTree as ET
for s in ET.parse(sys.argv[1]).getroot().iter("system"):
    exts = [e for e in (s.findtext("extension") or "").split() if e.lower() != ".sh"]
    for e in s.iter("emulator"):
        if exts and e.get("name") != "retroarch":
            for c in e.iter("core"):
                print("\t".join((s.findtext("name"), e.get("name"), c.text or "", s.findtext("path"), exts[0])))
EOF
}

launch_problems() {
  local rc=$1 rom=$2 script=${3##*/} name calls
  [ "${rc}" -eq 0 ] || echo "exit status ${rc}"
  grep -v '^+' /tmp/launch.err 2>/dev/null |
    grep -E 'command not found|syntax error|unbound variable|bad substitution|/(usr|etc|opt|bin|sbin|lib)/[^ ]*: No such file or directory' |
    sort -u
  name=${rom##*/}
  calls=$(grep -vE "^/[^ ]*/(${HELPERS})( |$)" /tmp/launch.calls 2>/dev/null)
  [ -n "${calls}" ] || { echo "no emulator started: $(tr '\n' ' ' 2>/dev/null </tmp/launch.calls)"; return; }
  [ -z "${rom}" ] || launchers_known "${script} rom" || [[ "${calls}" == *"${name%.*}"* ]] ||
    echo "ROM not passed to the emulator: ${calls//$'\n'/ }"
}

launch_one() {
  local rom=$4 rc
  mkdir -p "${rom%/*}"
  : >"${rom}"
  rm -f /tmp/launch.*
  LAUNCH_ROM=${rom} bash "${ROCKNIX_PKG}/sources/scripts/runemu.sh" "${rom}" -P"$1" --core="$3" --emulator="$2" \
    --controllers=" -p1index 0 -p1guid 19000000010000000100000000010000 " >/dev/null 2>&1
  rc=$?
  killall -9 gptokeyb 2>/dev/null
  return ${rc}
}

emulator_call() {
  grep "^$1 " /tmp/launch.calls 2>/dev/null | tail -n 1
}

test_launchers_start_every_emulator() {
  local system emulator core path ext rom rc script out failures="" launched=" " f
  launch_env
  while IFS="$(printf '\t')" read -r system emulator core path ext; do
    rom="${path}/My Games/Test Game (USA)${ext}"
    launch_one "${system}" "${emulator}" "${core}" "${rom}"
    rc=$?
    script=$(head -n 1 /tmp/launch.argv 2>/dev/null)
    [ -n "${script}" ] || continue
    launched="${launched}${script} "
    launchers_known "${script##*/}" && continue
    out=$(launch_problems "${rc}" "${rom}" "${script}")
    [ -z "${out}" ] || failures="${failures}${script##*/} (${system} ${emulator}/${core}):"$'\n'"${out}"$'\n'
  done < <(standalone_cores)
  for f in ${LAUNCHERS}; do
    case "${launched}" in *" ${f} "*) continue ;; esac
    launchers_known "${f##*/}" && continue
    rm -f /tmp/launch.*
    LAUNCH_ROM="" bash "${f}" >/dev/null 2>&1 </dev/null
    out=$(launch_problems "$?" "" "${f}")
    killall -9 gptokeyb 2>/dev/null
    [ -z "${out}" ] || failures="${failures}${f##*/} (no arguments):"$'\n'"${out}"$'\n'
  done
  [ -z "${failures}" ] || fail "start scripts that do not launch:"$'\n'"${failures}"
}

test_launchers_mednafen_module_and_rom() {
  local rom="/storage/roms/nes/My Games/Test Game (USA).nes" call
  [ -e /usr/bin/start_mednafen.sh ] || skip "no mednafen in this image"
  launch_env start_mednafen.sh
  launch_one nes mednafen nes "${rom}" || fail "runemu exited with $?:"$'\n'"$(cat /tmp/launch.err)"
  call=$(emulator_call /usr/bin/mednafen)
  assert_contains "${call}" "/usr/bin/mednafen [-force_module] [nes] " "mednafen module"
  [[ "${call}" == *" [${rom}]" ]] || fail "ROM is not the last argument: ${call}"
}

test_launchers_ppsspp_rom() {
  local rom="/storage/roms/psp/My Games/Test Game (USA).iso"
  [ -e /usr/bin/start_ppsspp.sh ] || skip "no PPSSPP in this image"
  launch_env start_ppsspp.sh
  launch_one psp ppsspp ppsspp-sa "${rom}" || fail "runemu exited with $?:"$'\n'"$(cat /tmp/launch.err)"
  assert_eq "$(emulator_call /usr/bin/ppsspp)" "/usr/bin/ppsspp [--pause-menu-exit] [${rom}]" "ppsspp command line"
}

test_launchers_dolphin_gc_rom() {
  local rom="/storage/roms/gamecube/My Games/Test Game (USA).rvz" call
  [ -e /usr/bin/start_dolphin_gc.sh ] || skip "no Dolphin in this image"
  launch_env start_dolphin_gc.sh
  launch_one gamecube dolphin dolphin-sa-gc "${rom}" || fail "runemu exited with $?:"$'\n'"$(cat /tmp/launch.err)"
  call=$(emulator_call /usr/bin/dolphin-emu-nogui)
  [[ "${call}" == *" [-e] [${rom}]" ]] || fail "dolphin-emu-nogui command line: ${call}"
}

test_launchers_gzdoom_wad_path_with_spaces() {
  local rom="/storage/roms/doom/My Games/Test Game (USA).wad"
  [ -e /usr/bin/start_gzdoom.sh ] || skip "no GZDoom in this image"
  launch_env start_gzdoom.sh
  launch_one doom gzdoom gzdoom-sa "${rom}" || fail "runemu exited with $?:"$'\n'"$(cat /tmp/launch.err)"
  assert_contains "$(emulator_call /usr/bin/gzdoom)" " [-iwad] [${rom}]" "gzdoom IWAD"
}
