# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

ROCKNIX_PKG=${REPO}/projects/ROCKNIX/packages/rocknix
SCRIPTS=${ROCKNIX_PKG}/sources/scripts
SYSTEM_CFG=/storage/.config/system/configs/system.cfg
RA_CFG=/storage/.config/retroarch/retroarch.cfg
RA_APPEND=/tmp/.retroarch.cfg
CONTROLLERS=" -p1index 0 -p1guid 19000000010000000100000000010000 "
ROM_NES="/storage/roms/nes/My Hacks/Kirby's Adventure & Friends (USA) [!].nes"
ROM_NES_GAME="nes[\"Kirby's Adventure & Friends (USA) [!].nes\"]"

launch_env() {
  STUBBED="/usr/bin/setsettings.sh /usr/bin/game-guides-tool"
  trap launch_cleanup EXIT
  mv /etc/profile.d/001-functions /run/emulation-001-functions
  cp "${ROCKNIX_PKG}/profile.d/001-functions" /etc/profile.d/001-functions
  stub /usr/bin/setsettings.sh <<EOF
#!/bin/bash
exec /bin/bash "${SCRIPTS}/setsettings.sh" "\$@"
EOF
  stub /usr/bin/game-guides-tool <<EOF
#!/bin/bash
exec /bin/bash "${REPO}/projects/ROCKNIX/packages/apps/sdl2text/scripts/game-guides-tool" "\$@"
EOF
  mkdir -p /storage/.config/system/configs /storage/.config/retroarch /storage/.config/profile.d \
    /storage/roms/savestates /var/log
  cp "${ROCKNIX_PKG}/config/system/configs/system.cfg" "${SYSTEM_CFG}"
  cp /usr/config/retroarch/retroarch.cfg "${RA_CFG}"
  cat >/storage/.config/profile.d/zz-emulation-test <<'EOF'
set_cpu_gov() { echo "$1" >>/tmp/emu.gov; }
set_dmc_gov() { :; }
set_gpu_gov() { echo "$1" >>/tmp/emu.gpu; }
set_online_threads() { echo "$*" >>/tmp/emu.threads; }
EOF
}

launch_cleanup() {
  unstub ${STUBBED}
  [ -e /run/emulation-001-functions ] && mv -f /run/emulation-001-functions /etc/profile.d/001-functions
  rm -rf /storage/.config /storage/roms /tmp/emu.* "${RA_APPEND}" /tmp/.overlay.cfg /tmp/.process-kill-data \
    /tmp/.system.cfg.lock /tmp/.gpu_performance_level /tmp/launch_error.log /tmp/shader /tmp/joypads \
    /var/log/exec.log /run/rocknix
  rmdir /run/systemd/system /run/systemd 2>/dev/null
  return 0
}

emulator() {
  STUBBED="${STUBBED} $1"
  stub "$1" <<'EOF'
#!/bin/bash
{
  echo "$0"
  for a in "$@"; do echo "[$a]"; done
} >/tmp/emu.argv
cp /tmp/.process-kill-data /tmp/emu.kill 2>/dev/null
cp /tmp/.retroarch.cfg /tmp/emu.append 2>/dev/null
cat /tmp/emu.gov >/tmp/emu.gov.running 2>/dev/null
env >/tmp/emu.env
cp /run/rocknix/fullscreen-scale-hint /tmp/emu.hint 2>/dev/null
rm -rf /tmp/emu.dpu.running
cp -r /tmp/emu.dpu /tmp/emu.dpu.running 2>/dev/null
exit "$(cat /tmp/emu.rc 2>/dev/null || echo 0)"
EOF
}

systemd_env() {
  STUBBED="${STUBBED} /usr/bin/systemd-run /usr/bin/systemctl /usr/bin/journalctl"
  mkdir -p /run/systemd/system
  stub /usr/bin/systemd-run <<'EOF'
#!/bin/bash
for a in "$@"; do echo "[$a]"; done >/tmp/emu.scope
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
EOF
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/emu.systemctl
EOF
  stub /usr/bin/journalctl <<'EOF'
#!/bin/sh
cat /tmp/emu.journal 2>/dev/null
EOF
}

scanout_env() {
  STUBBED="${STUBBED} /usr/bin/swaymsg"
  stub /usr/bin/swaymsg <<'EOF'
#!/bin/sh
if [ "$1" = "-t" ]; then
  cat /tmp/emu.outputs
else
  echo "$*" >>/tmp/emu.swaymsg
fi
EOF
  echo '[{"name":"DSI-1","active":true,"focused":true,"transform":"270","current_mode":{"width":1080,"height":1920}}]' \
    >/tmp/emu.outputs
  mkdir -p /tmp/emu.dpu
  [ "$1" = "off" ] && return 0
  printf '%s\n' DEVICE_SCANOUT_SCALING=true DEVICE_SCANOUT_SHARPNESS=/tmp/emu.dpu \
    >>/storage/.config/profile.d/zz-emulation-test
}

dpu_state() {
  local f
  for f in nearest de_dir de_dir_weight de de_sharpen1 de_sharpen2 de_unscaled; do
    printf '%s=%s ' "${f}" "$(cat "$1/dpu_${f}" 2>/dev/null)"
  done
}

scanout_vars() {
  grep -E '^(SCANOUT_(RENDER|MAX_RENDER|OUTPUT|TRANSFORM)|GDK_SCALE)=' /tmp/emu.env | LC_ALL=C sort | tr '\n' ' '
}

setting() {
  awk -v k="$1=" 'index($0, k) != 1' "${SYSTEM_CFG}" >"${SYSTEM_CFG}.new"
  echo "$1=$2" >>"${SYSTEM_CFG}.new"
  mv "${SYSTEM_CFG}.new" "${SYSTEM_CFG}"
}

make_rom() {
  mkdir -p "$(dirname "$1")"
  : >"$1"
}

runemu() {
  bash "${SCRIPTS}/runemu.sh" "$@" >/tmp/emu.out 2>&1
}

launch() {
  local rom=$1 platform=$2 core=$3 emu=$4
  shift 4
  make_rom "${rom}"
  rm -f /tmp/emu.argv /tmp/emu.append
  runemu "${rom}" -P"${platform}" --core="${core}" --emulator="${emu}" --controllers="${CONTROLLERS}" "$@"
}

ra_value() {
  grep "^$1 = " "${2:-${RA_APPEND}}" 2>/dev/null | sed 's/^[^=]* = "\(.*\)"$/\1/'
}

argv() {
  tr '\n' ' ' </tmp/emu.argv | sed 's/ $//'
}

setsettings() {
  local platform=$1 rom=$2 core=$3
  shift 3
  bash "${SCRIPTS}/setsettings.sh" "${platform}" "${rom}" "${core}" --controllers="${CONTROLLERS}" \
    --autosave="${AUTOSAVE_ARG}" --snapshot="${SNAPSHOT_ARG}" "$@" 2>/dev/null
}

wait_for_line() {
  local i
  for i in $(seq 30); do
    grep -qxF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

test_runemu_retroarch_core_and_rom_path() {
  launch_env
  emulator /usr/bin/retroarch
  setting global.shaderset none
  launch "${ROM_NES}" nes fceumm retroarch || fail "runemu exited with $?:"$'\n'"$(cat /tmp/emu.out)"
  assert_eq "$(argv)" \
    "/usr/bin/retroarch [-L] [/tmp/cores/fceumm_libretro.so] [--config] [${RA_CFG}] [--appendconfig] [${RA_APPEND}] [${ROM_NES}]" \
    "retroarch command line"
  assert_eq "$(cat /tmp/emu.kill)" "retroarch retroarch32" "exit hotkey target while the game runs"
  assert_eq "$(ra_value savestate_directory /tmp/emu.append)" /storage/roms/savestates/nes \
    "appendconfig ready before the game starts"
  [ -d /storage/roms/savestates/nes ] || fail "savestate directory not created"
}

test_runemu_32bit_cores_use_retroarch32() {
  . /etc/os-release
  [ "${HW_ARCH}" = "aarch64" ] || skip "32-bit RetroArch is only used on aarch64"
  launch_env
  emulator /usr/bin/retroarch
  emulator /usr/bin/retroarch32
  setting global.shaderset none
  launch "/storage/roms/gba/Golden Sun (USA).gba" gba gpsp retroarch
  assert_eq "$(head -n 3 /tmp/emu.argv | tr '\n' ' ')" "/usr/bin/retroarch32 [-L] [/tmp/cores/gpsp_libretro.so] " gpsp
  launch "/storage/roms/psx/Final Fantasy VII (Disc 1).chd" psx pcsx_rearmed32 retroarch
  assert_eq "$(head -n 3 /tmp/emu.argv | tr '\n' ' ')" \
    "/usr/bin/retroarch32 [-L] [/tmp/cores/pcsx_rearmed32_libretro.so] " pcsx_rearmed32
  launch "/storage/roms/gba/Golden Sun (USA).gba" gba mgba retroarch
  assert_eq "$(head -n 3 /tmp/emu.argv | tr '\n' ' ')" "/usr/bin/retroarch [-L] [/tmp/cores/mgba_libretro.so] " mgba
}

test_runemu_standalone_start_scripts() {
  local rom
  launch_env
  emulator /usr/bin/retroarch
  emulator /usr/bin/start_ppsspp.sh
  emulator /usr/bin/start_mupen64plus.sh
  emulator /usr/bin/start_dolphin_gc.sh
  emulator /usr/bin/start_mednafen.sh
  rom="/storage/roms/psp/God of War - Chains of Olympus (USA).iso"
  launch "${rom}" psp ppsspp-sa ppsspp
  assert_eq "$(argv)" "/usr/bin/start_ppsspp.sh [${rom}] [psp]" ppsspp
  rom="/storage/roms/n64/Legend of Zelda, The - Majora's Mask (USA).z64"
  launch "${rom}" n64 mupen64plus-sa mupen64plus
  assert_eq "$(argv)" "/usr/bin/start_mupen64plus.sh [${rom}] [n64]" mupen64plus
  rom="/storage/roms/gamecube/Super Mario Sunshine (USA).rvz"
  launch "${rom}" gamecube dolphin-sa-gc dolphin
  assert_eq "$(argv)" "/usr/bin/start_dolphin_gc.sh [${rom}] [gamecube] [dolphin-sa-gc]" dolphin
  rom="/storage/roms/atarilynx/California Games (USA, Europe).lnx"
  launch "${rom}" atarilynx lynx mednafen
  assert_eq "$(argv)" "/usr/bin/start_mednafen.sh [${rom}] [lynx] [atarilynx]" mednafen
  [ -e "${RA_APPEND}" ] && fail "setsettings ran for a standalone emulator"
  return 0
}

test_runemu_ports_script() {
  local rc rom="/storage/roms/ports/Baldur's Gate II.sh"
  [ -f /usr/config/PortMaster/mapper.txt ] || skip "no PortMaster in this image"
  launch_env
  mkdir -p /storage/.config/PortMaster /storage/roms/ports
  cp /usr/config/PortMaster/mapper.txt /storage/.config/PortMaster/mapper.txt
  cat >"${rom}" <<'EOF'
#!/bin/bash
{
  echo "$0"
  for a in "$@"; do echo "[$a]"; done
} >/tmp/emu.argv
exit 3
EOF
  chmod 644 "${rom}"
  runemu "${rom}" -Pports --core=portmaster --emulator=portmaster --controllers="${CONTROLLERS}"
  rc=$?
  assert_eq "$(argv)" "${rom}" "port script run"
  assert_eq "${rc}" 1 "exit code of a failing port"
  assert_eq "$(stat -c %A "${rom}")" "-rwxr-xr-x" "port script mode"
  assert_eq "$(grep '^ACTIVE_' /storage/.config/PortMaster/mapper.txt | tr '\n' ' ')" \
    "ACTIVE_GAME=\"${rom}\" ACTIVE_PLATFORM=\"ports\" " "PortMaster mapper"
}

test_runemu_exit_status() {
  local pair
  launch_env
  emulator /usr/bin/retroarch
  for pair in 0:0 137:0 143:0 1:1 2:1 250:1; do
    echo "${pair%:*}" >/tmp/emu.rc
    echo "stale message" >/tmp/launch_error.log
    launch "${ROM_NES}" nes fceumm retroarch
    assert_eq "$?" "${pair#*:}" "runemu exit code when the emulator exits with ${pair%:*}"
    [ -e /tmp/launch_error.log ] && fail "stale /tmp/launch_error.log kept after exit ${pair%:*}"
  done
  return 0
}

test_runemu_game_runs_in_games_slice_scope() {
  local unit
  launch_env
  systemd_env
  emulator /usr/bin/retroarch
  launch "${ROM_NES}" nes fceumm retroarch || fail "runemu exited with $?:"$'\n'"$(cat /tmp/emu.out)"
  [ -s /tmp/emu.argv ] || fail "the emulator did not run inside systemd-run"
  grep -qx '\[--scope\]' /tmp/emu.scope || fail "not a scope:"$'\n'"$(cat /tmp/emu.scope)"
  grep -qx '\[--slice=games.slice\]' /tmp/emu.scope || fail "not in games.slice:"$'\n'"$(cat /tmp/emu.scope)"
  grep -qxF "[--description=nes: ${ROM_NES##*/}]" /tmp/emu.scope || fail "description:"$'\n'"$(cat /tmp/emu.scope)"
  unit=$(sed -n 's/^\[--unit=\(game-[0-9]*\)\]$/\1/p' /tmp/emu.scope)
  [ -n "${unit}" ] || fail "no game-<pid> unit:"$'\n'"$(cat /tmp/emu.scope)"
  grep -qx "stop ${unit}.scope" /tmp/emu.systemctl || fail "scope not stopped:"$'\n'"$(cat /tmp/emu.systemctl)"
  assert_eq "$(sed -n '/^\[--\]$/,$p' /tmp/emu.scope | sed -n 2p)" "[/usr/bin/retroarch]" "command after --"
}

test_runemu_oom_kill_reports_launch_error() {
  local rc
  launch_env
  systemd_env
  emulator /usr/bin/retroarch
  echo 137 >/tmp/emu.rc
  launch "${ROM_NES}" nes fceumm retroarch
  assert_eq "$?" 0 "exit hotkey kill without an OOM kill"
  echo "systemd-oomd killed 4 process(es) in this unit." >/tmp/emu.journal
  launch "${ROM_NES}" nes fceumm retroarch
  rc=$?
  assert_eq "${rc}" 250 "exit code ES shows launch_error.log for"
  assert_contains "$(cat /tmp/launch_error.log 2>/dev/null)" "ran out of memory" "launch error message"
}

test_runemu_cpu_governor_precedence() {
  launch_env
  emulator /usr/bin/retroarch
  emulator /usr/bin/start_ppsspp.sh
  setting system.cpugovernor schedutil
  setting nes.cpugovernor ondemand
  setting "${ROM_NES_GAME}.cpugovernor" powersave
  launch "${ROM_NES}" nes fceumm retroarch
  assert_eq "$(tail -n 1 /tmp/emu.gov.running)" powersave "per-game governor while the game runs"
  assert_eq "$(tail -n 1 /tmp/emu.gov)" schedutil "system governor after the game"
  rm -f /tmp/emu.gov
  launch "/storage/roms/nes/Super Mario Bros. (World).nes" nes fceumm retroarch
  assert_eq "$(tail -n 1 /tmp/emu.gov.running)" ondemand "platform governor"
  rm -f /tmp/emu.gov
  launch "/storage/roms/psp/Lumines (USA).iso" psp ppsspp-sa ppsspp
  assert_eq "$(tr '\n' ' ' </tmp/emu.gov)" "performance schedutil performance schedutil " \
    "governor sequence for a standalone emulator"
}

test_runemu_restores_state_after_game() {
  launch_env
  emulator /usr/bin/retroarch
  setting netplay.mode host
  setting system.threads 3
  setting system.gpuperf powersave
  setting "${ROM_NES_GAME}.threads" 2
  setting nes.gpuperf performance
  launch "${ROM_NES}" nes fceumm retroarch
  grep -qx "2 0" /tmp/emu.threads || fail "per-game thread count not applied:"$'\n'"$(cat /tmp/emu.threads)"
  grep -qx performance /tmp/emu.gpu || fail "platform GPU governor not applied:"$'\n'"$(cat /tmp/emu.gpu)"
  assert_eq "$(cat /tmp/.process-kill-data)" "emulationstation" "exit hotkey target after the game"
  grep -q '^netplay.mode=' "${SYSTEM_CFG}" && fail "stale netplay.mode kept"
  [ -e /tmp/shader ] && fail "/tmp/shader left behind"
  [ -e /tmp/.gpu_performance_level ] && fail "/tmp/.gpu_performance_level left behind"
  wait_for_line /tmp/emu.threads "3 0" || fail "system thread count not restored:"$'\n'"$(cat /tmp/emu.threads)"
  wait_for_line /tmp/emu.gpu powersave || fail "system GPU governor not restored:"$'\n'"$(cat /tmp/emu.gpu)"
}

test_runemu_atomiswave_resets_nvmem() {
  local rom
  launch_env
  emulator /usr/bin/retroarch
  for rom in /storage/roms/atomiswave/dolphin.zip "/storage/roms/atomiswave/Dolphin Blue (Japan).zip"; do
    make_rom "${rom}.nvmem"
    make_rom "${rom}.nvmem2"
    launch "${rom}" atomiswave flycast retroarch
    [ -e "${rom}" ] || fail "${rom} removed"
    [ -e "${rom}.nvmem" ] || [ -e "${rom}.nvmem2" ] && fail "NVRAM of ${rom##*/} kept"
  done
  return 0
}

test_runemu_savestate_slot_from_es() {
  launch_env
  emulator /usr/bin/retroarch
  setting global.autosave 0
  launch "${ROM_NES}" nes fceumm retroarch -autosave 1 -state_slot 3
  assert_eq "$(ra_value state_slot)" 3 "state slot"
  assert_eq "$(ra_value savestate_auto_load)" true "autoload requested by ES"
  setting global.autosave 1
  launch "${ROM_NES}" nes fceumm retroarch -autosave 0 -state_slot 2
  assert_eq "$(ra_value state_slot)" 2 "state slot"
  assert_eq "$(ra_value savestate_auto_load)" false "autoload refused by ES"
  launch "${ROM_NES}" nes fceumm retroarch -state_slot 5 -state_file "/storage/roms/savestates/nes/x.state5"
  assert_eq "$(ra_value state_slot)" 5 "state slot with a state file"
  assert_eq "$(ra_value savestate_auto_load)" true "autoload from the setting"
}

test_runemu_controllers_set_joypad_index() {
  launch_env
  emulator /usr/bin/retroarch
  make_rom "${ROM_NES}"
  runemu "${ROM_NES}" -Pnes --core=fceumm --emulator=retroarch \
    --controllers=" -p1index 2 -p1guid 03000000de2800000112000001000000 -p2index 0 -p2guid 19000000010000000100000000010000 "
  assert_eq "$(ra_value input_player1_joypad_index)" 2 "player 1"
  assert_eq "$(ra_value input_player2_joypad_index)" 0 "player 2"
  assert_eq "$(ra_value input_player3_joypad_index)" "" "player 3"
}

test_runemu_netplay_host_from_es() {
  launch_env
  emulator /usr/bin/retroarch
  setting global.shaderset none
  setting global.netplay 1
  setting global.netplay.nickname Bob
  setting global.netplay.port 55435
  launch "${ROM_NES}" nes fceumm retroarch --host --port 55435 --nick Bob
  assert_contains "$(argv)" "[--host] [--config]" "host option"
  assert_eq "$(grep '^netplay.mode=' "${SYSTEM_CFG}")" "netplay.mode=host" "netplay mode"
  assert_eq "$(ra_value netplay_ip_port)" 55435 "port"
  assert_eq "$(ra_value netplay_nickname)" Bob "nickname"
  assert_eq "$(ra_value netplay_mode)" false "server mode"
}

test_runemu_registers_game_guide() {
  launch_env
  emulator /usr/bin/retroarch
  make_rom "${ROM_NES%.*}.txt"
  launch "${ROM_NES}" nes fceumm retroarch
  assert_eq "$(cat /storage/.config/sdl2text/game_guide.path 2>/dev/null)" "${ROM_NES%.*}.txt" "guide path"
  launch "/storage/roms/nes/Super Mario Bros. (World).nes" nes fceumm retroarch
  [ -e /storage/.config/sdl2text/game_guide.path ] && fail "guide of the previous game kept"
  return 0
}

test_runemu_scanout_scaling_percent_of_screen() {
  local owner
  launch_env
  scanout_env
  emulator /usr/bin/retroarch
  setting nes.rocknix.scaling.render 50
  setting global.rocknix.scaling.filter hardware_nearest
  setting global.rocknix.scaling.sharpness 10
  launch "${ROM_NES}" nes fceumm retroarch || fail "runemu exited with $?:"$'\n'"$(cat /tmp/emu.out)"
  assert_eq "$(scanout_vars)" \
    "GDK_SCALE=1.0001 SCANOUT_MAX_RENDER=400 SCANOUT_OUTPUT=DSI-1 SCANOUT_RENDER=50 SCANOUT_TRANSFORM=270 " \
    "game environment"
  owner=$(sed -n 's/^SCANOUT_OWNER=//p' /tmp/emu.env)
  assert_eq "$(cat /tmp/emu.hint)" "0.500000 ${owner} DSI-1" "fullscreen scale hint"
  assert_eq "$(dpu_state /tmp/emu.dpu.running)" \
    "nearest=Y de_dir=N de_dir_weight= de=Y de_sharpen1=24 de_sharpen2=24 de_unscaled=Y " \
    "plane filter while the game runs"
  assert_eq "$(tr '\n' ',' </tmp/emu.swaymsg)" "output DSI-1 scale 2.000000,output DSI-1 scale 1," "output scale"
  assert_eq "$(dpu_state /tmp/emu.dpu)" \
    "nearest=N de_dir=N de_dir_weight=32 de=Y de_sharpen1=12 de_sharpen2=12 de_unscaled=N " \
    "plane filter after the game"
  [ -e /run/rocknix/scanout-owner ] && fail "scan-out owner left behind"
  [ -e /run/rocknix/fullscreen-scale-hint ] && fail "scale hint left behind"
  return 0
}

test_runemu_scanout_scaling_native_multiple() {
  launch_env
  scanout_env
  emulator /usr/bin/start_ppsspp.sh
  setting psp.rocknix.scaling.render 2x
  launch "/storage/roms/psp/Lumines (USA).iso" psp ppsspp-sa ppsspp || fail "runemu exited with $?:"$'\n'"$(cat /tmp/emu.out)"
  assert_eq "$(scanout_vars)" \
    "GDK_SCALE=1.0001 SCANOUT_MAX_RENDER=400 SCANOUT_OUTPUT=DSI-1 SCANOUT_RENDER=2x SCANOUT_TRANSFORM=270 " \
    "game environment"
  assert_eq "$(cut -d' ' -f1 /tmp/emu.hint)" 0.504202 "544 of 1080 lines"
  assert_eq "$(head -n 1 /tmp/emu.swaymsg)" "output DSI-1 scale 1.983333" "output scale"
  assert_eq "$(dpu_state /tmp/emu.dpu.running)" \
    "nearest=N de_dir=N de_dir_weight= de=N de_sharpen1= de_sharpen2= de_unscaled= " \
    "plane filter while the game runs"
}

test_runemu_resets_stale_scanout_state() {
  launch_env
  scanout_env off
  emulator /usr/bin/retroarch
  mkdir -p /run/rocknix
  echo 999999 >/run/rocknix/scanout-owner
  echo DSI-1 >/run/rocknix/scanout-scaled-outputs
  echo "0.500000 999999 DSI-1" >/run/rocknix/fullscreen-scale-hint
  launch "${ROM_NES}" nes fceumm retroarch
  assert_eq "$(cat /tmp/emu.swaymsg 2>/dev/null)" "output DSI-1 scale 1" "scale of the crashed game reset"
  [ -e /tmp/emu.hint ] && fail "stale scale hint seen by the game"
  [ -e /run/rocknix/scanout-owner ] && fail "stale owner kept"
  return 0
}

test_setsettings_ratio_precedence() {
  launch_env
  setting global.ratio core
  setting gba.ratio 3/2
  setting nes.ratio 4/3
  setting "${ROM_NES_GAME}.ratio" 16/9
  setsettings gb "/storage/roms/gb/Tetris (World).gb" gambatte >/dev/null
  assert_eq "$(ra_value aspect_ratio_index)" 22 "global ratio core"
  setsettings gba "/storage/roms/gba/Golden Sun (USA).gba" mgba >/dev/null
  assert_eq "$(ra_value aspect_ratio_index)" 7 "platform ratio 3/2"
  setsettings nes "/storage/roms/nes/Super Mario Bros. (World).nes" fceumm >/dev/null
  assert_eq "$(ra_value aspect_ratio_index)" 0 "platform ratio 4/3"
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value aspect_ratio_index)" 1 "per-game ratio 16/9"
  setting nes.ratio full
  setsettings nes "/storage/roms/nes/Super Mario Bros. (World).nes" fceumm >/dev/null
  assert_eq "$(ra_value aspect_ratio_index)" 24 "ratio full"
}

test_setsettings_scaling_and_smoothing() {
  launch_env
  setting global.smooth 1
  setting nes.integerscale 0
  setting "${ROM_NES_GAME}.integerscale" 1
  setting "${ROM_NES_GAME}.smooth" 0
  setsettings nes "/storage/roms/nes/Super Mario Bros. (World).nes" fceumm >/dev/null
  assert_eq "$(ra_value video_scale_integer)" 0 "platform integer scaling"
  assert_eq "$(ra_value video_smooth)" 1 "global smoothing"
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value video_scale_integer)" 1 "per-game integer scaling"
  assert_eq "$(ra_value video_smooth)" 0 "per-game smoothing"
}

test_setsettings_rewind_and_runahead_per_platform() {
  launch_env
  setting global.rewind 1
  setting global.runahead 2
  setting global.secondinstance 1
  setting global.analogue 1
  setsettings snes "/storage/roms/snes/Super Metroid (USA).sfc" snes9x >/dev/null
  assert_eq "$(ra_value rewind_enable)" true "snes rewind"
  assert_eq "$(ra_value run_ahead_enabled)/$(ra_value run_ahead_frames)" true/2 "snes run-ahead"
  assert_eq "$(ra_value run_ahead_secondary_instance)" 1 "snes second instance"
  assert_eq "$(ra_value input_player1_analog_dpad_mode)" 1 "snes analog stick as d-pad"
  setsettings n64 "/storage/roms/n64/Super Mario 64 (USA).z64" mupen64plus_next >/dev/null
  assert_eq "$(ra_value rewind_enable)" false "n64 rewind"
  assert_eq "$(ra_value run_ahead_enabled)/$(ra_value run_ahead_frames)" false/0 "n64 run-ahead"
  assert_eq "$(ra_value input_player1_analog_dpad_mode)" 0 "n64 analog stick"
}

test_setsettings_shader_and_filter() {
  local out
  launch_env
  setting nes.shaderset crt/crt-easymode.glslp
  setting snes.shaderset none
  setting gba.videofilter Scanline2x.filt
  out=$(setsettings nes "${ROM_NES}" fceumm)
  assert_eq "${out}" " --set-shader /tmp/shaders/crt/crt-easymode.glslp" "shader option"
  assert_eq "$(ra_value video_shader_enable)" true "shader enabled"
  assert_eq "$(ra_value video_shader)" crt/crt-easymode.glslp "shader preset"
  out=$(setsettings snes "/storage/roms/snes/Super Metroid (USA).sfc" snes9x)
  assert_eq "${out}" "" "no shader option"
  assert_eq "$(ra_value video_shader_enable)" false "shader disabled"
  setsettings gba "/storage/roms/gba/Golden Sun (USA).gba" mgba >/dev/null
  assert_eq "$(ra_value video_filter)" /usr/share/retroarch/filters/64bit/video/Scanline2x.filt "64-bit filter"
  setsettings gba "/storage/roms/gba/Golden Sun (USA).gba" gpsp >/dev/null
  assert_eq "$(ra_value video_filter)" /usr/share/retroarch/filters/32bit/video/Scanline2x.filt "32-bit filter"
}

test_setsettings_unset_shader_filter_translation_stay_off() {
  local out
  launch_env
  out=$(setsettings snes "/storage/roms/snes/Super Metroid (USA).sfc" snes9x)
  assert_eq "${out}" "" "options passed to retroarch with shaderset on AUTO"
  [ "$(ra_value video_shader_enable)" = true ] && fail "shader enabled with shaderset on AUTO"
  assert_eq "$(ra_value video_filter)" "" "video filter with videofilter on AUTO"
  [ "$(ra_value ai_service_enable)" = true ] && fail "AI service enabled without ai_service_enabled"
  return 0
}

test_setsettings_autosave_and_savestates() {
  launch_env
  setting global.autosave 1
  setting arcade.autosave 0
  setting global.incrementalsavestates 1
  setting global.maxincrementalsaves 5
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value savestate_auto_load)/$(ra_value savestate_auto_save)" true/true "global autosave"
  assert_eq "$(ra_value savestate_auto_index)/$(ra_value savestate_max_keep)" true/5 "incremental save states"
  assert_eq "$(ra_value state_slot)" "" "no slot unless ES asks"
  AUTOSAVE_ARG=0 SNAPSHOT_ARG=4 setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value savestate_auto_load)/$(ra_value savestate_auto_save)" false/false "autosave refused by ES"
  assert_eq "$(ra_value state_slot)" 4 "slot from ES"
  setsettings arcade "/storage/roms/arcade/sf2.zip" fbneo >/dev/null
  assert_eq "$(ra_value savestate_auto_load)" false "arcade autosave off at platform level"
  assert_eq "$(ra_value savestate_directory)" /storage/roms/savestates/arcade "arcade savestate directory"
}

test_setsettings_retroachievements() {
  launch_env
  setting global.retroachievements 1
  setting global.retroachievements.username player1
  setting global.retroachievements.password testpass
  setting global.retroachievements.hardcore 1
  setsettings snes "/storage/roms/snes/Super Metroid (USA).sfc" snes9x >/dev/null
  assert_eq "$(ra_value cheevos_enable)" true "snes cheevos"
  assert_eq "$(ra_value cheevos_username)" player1 username
  assert_eq "$(ra_value cheevos_password)" testpass password
  assert_eq "$(ra_value cheevos_hardcore_mode_enable)" 1 hardcore
  assert_eq "$(ra_value cheevos_cmd)" /usr/share/libretro/call_achievements_hooks.sh "achievement hook"
  setsettings scummvm "/storage/roms/scummvm/monkey.scummvm" scummvm >/dev/null
  assert_eq "$(ra_value cheevos_enable)" false "scummvm has no achievements"
  assert_eq "$(ra_value cheevos_username)" "" "no credentials without achievements"
}

test_setsettings_retroarch_paths() {
  launch_env
  sed -i 's|^libretro_directory = .*|libretro_directory = "/storage/cores"|' "${RA_CFG}"
  echo 'cache_directory = "/storage/cache"' >>"${RA_CFG}"
  echo 'input_player1_joypad_index = "3"' >>"${RA_CFG}"
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value libretro_directory "${RA_CFG}")" /tmp/cores "libretro_directory"
  assert_eq "$(ra_value cache_directory "${RA_CFG}")" /tmp/cache "cache_directory"
  assert_eq "$(ra_value joypad_autoconfig_dir "${RA_CFG}")" /tmp/joypads "joypad_autoconfig_dir"
  assert_eq "$(ra_value overlay_directory "${RA_CFG}")" /tmp/overlays "overlay_directory"
  grep -q '^input_player1_joypad_index' "${RA_CFG}" && fail "per-player input left in retroarch.cfg"
  return 0
}

test_setsettings_keeps_video_shader_dir() {
  launch_env
  setting nes.shaderset crt/crt-easymode.glslp
  echo 'video_shader_dir = "/storage/shaders"' >>"${RA_CFG}"
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value video_shader_dir "${RA_CFG}")" /tmp/shaders "video_shader_dir in retroarch.cfg"
}

test_setsettings_autohotkeys_from_joypad_autoconfig() {
  grep -qE 'js0|joypad|DualSense' /proc/bus/input/devices 2>/dev/null && skip "a host joypad is visible in the container"
  launch_env
  setting system.autohotkeys 1
  mkdir -p /tmp/joypads
  cat >/tmp/joypads/.cfg <<'EOF'
input_driver = "udev"
input_device = "Test Pad"
input_select_btn = "6"
input_start_btn = "7"
input_x_btn = "3"
input_y_btn = "2"
input_l_btn = "4"
input_r_btn = "5"
input_l2_axis = "+2"
input_r2_axis = "+5"
EOF
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value input_enable_hotkey_btn "${RA_CFG}")" 6 "hotkey is select"
  assert_eq "$(ra_value input_exit_emulator_btn "${RA_CFG}")" 7 "select+start exits"
  assert_eq "$(ra_value input_menu_toggle_btn "${RA_CFG}")" 3 "select+x opens the menu"
  assert_eq "$(ra_value input_save_state_btn "${RA_CFG}")/$(ra_value input_load_state_btn "${RA_CFG}")" 5/4 \
    "save/load state"
  assert_eq "$(ra_value input_toggle_fast_forward_axis "${RA_CFG}")/$(ra_value input_rewind_axis "${RA_CFG}")" +5/+2 \
    "trigger axes"
  setting system.autohotkeys 0
  sed -i '/^input_exit_emulator_btn/d' "${RA_CFG}"
  echo 'input_exit_emulator_btn = "nul"' >>"${RA_CFG}"
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value input_exit_emulator_btn "${RA_CFG}")" nul "hotkeys left alone when disabled"
}

test_setsettings_bezel_lookup() {
  local bezels=/storage/roms/bezels/thebezelproject rom2="/storage/roms/nes/Super Mario Bros. (World).nes"
  launch_env
  setting global.bezel thebezelproject
  mkdir -p "${bezels}/games/nes" "${bezels}/systems"
  : >"${bezels}/games/nes/Kirby's Adventure & Friends (USA) [!].png"
  : >"${bezels}/systems/nes.png"
  : >"${bezels}/default.png"
  setsettings nes "${ROM_NES}" fceumm >/dev/null
  assert_eq "$(ra_value overlay0_overlay /tmp/.overlay.cfg)" \
    "${bezels}/games/nes/Kirby's Adventure & Friends (USA) [!].png" \
    "game bezel"
  assert_eq "$(ra_value input_overlay)/$(ra_value input_overlay_enable)" "/tmp/.overlay.cfg/true" "overlay enabled"
  setsettings nes "${rom2}" fceumm >/dev/null
  assert_eq "$(ra_value overlay0_overlay /tmp/.overlay.cfg)" "${bezels}/systems/nes.png" "system bezel"
  setsettings gb "/storage/roms/gb/Tetris (World).gb" gambatte >/dev/null
  assert_eq "$(ra_value overlay0_overlay /tmp/.overlay.cfg)" "${bezels}/default.png" "default bezel"
}

test_setsettings_gambatte_keeps_core_options() {
  local opt=/storage/.config/retroarch/config/Gambatte/Gambatte.opt
  launch_env
  mkdir -p "${opt%/*}"
  printf '%s\n' 'gambatte_gb_bootloader = "disabled"' 'gambatte_gb_colorization = "custom"' >"${opt}"
  setting gb.renderer.colorization GBC
  setsettings gb "/storage/roms/gb/Tetris (World).gb" gambatte >/dev/null
  assert_eq "$(ra_value gambatte_gb_colorization "${opt}")" GBC "colorization"
  assert_eq "$(ra_value gambatte_gb_bootloader "${opt}")" disabled "user core option kept"
}

test_setsettings_netplay_client_uses_configured_port() {
  local out
  launch_env
  setting global.netplay 1
  setting global.netplay.port 55500
  setting global.netplay.host 192.168.1.20
  setting netplay.mode client
  out=$(setsettings snes "/storage/roms/snes/Super Metroid (USA).sfc" snes9x)
  assert_contains "${out}" " --connect 192.168.1.20" "connect option"
  assert_eq "$(ra_value netplay_mode)" true "client mode"
  assert_eq "$(ra_value netplay_ip_port)" 55500 "port of the host"
}

test_setsettings_netplay_overrides_autosave_and_hardcore() {
  launch_env
  setting global.netplay 1
  setting netplay.mode host
  setting global.autosave 1
  setting global.retroachievements 1
  setting global.retroachievements.hardcore 1
  setsettings snes "/storage/roms/snes/Super Metroid (USA).sfc" snes9x >/dev/null
  assert_eq "$(ra_value savestate_auto_load)" false "autoload during netplay"
  assert_eq "$(ra_value savestate_auto_save)" false "autosave during netplay"
  assert_eq "$(ra_value cheevos_hardcore_mode_enable)" false "hardcore during netplay"
}

test_setemu_set_and_get() {
  local key="nes[\"Kirby's Adventure (USA) [!].nes\"].core" conf=/storage/.config/system/configs/emuoptions.conf
  launch_env
  bash "${SCRIPTS}/setemu.sh" set nes.core fceumm
  bash "${SCRIPTS}/setemu.sh" set nes.core nestopia
  assert_eq "$(cat "${conf}")" "nes.core=nestopia" "value replaced"
  assert_eq "$(bash "${SCRIPTS}/setemu.sh" get nes.core)" nestopia "get"
  bash "${SCRIPTS}/setemu.sh" set "${key}" mesen
  assert_eq "$(bash "${SCRIPTS}/setemu.sh" get "${key}")" mesen "per-game get"
  bash "${SCRIPTS}/setemu.sh" set "${key}" auto
  assert_eq "$(bash "${SCRIPTS}/setemu.sh" get "${key}")" "" "auto removes the value"
  bash "${SCRIPTS}/setemu.sh" set nes.core disable
  assert_eq "$(cat "${conf}")" "#nes.core=" "disable comments the key out"
  assert_eq "$(bash "${SCRIPTS}/setemu.sh" get nes.core)" "" "disabled value"
}

test_setemu_set_keeps_other_keys() {
  local conf=/storage/.config/system/configs/emuoptions.conf
  launch_env
  bash "${SCRIPTS}/setemu.sh" set snes.core snes9x
  bash "${SCRIPTS}/setemu.sh" set nes.core fceumm
  assert_eq "$(sort "${conf}" | tr '\n' ' ')" "nes.core=fceumm snes.core=snes9x " "emuoptions.conf"
}
