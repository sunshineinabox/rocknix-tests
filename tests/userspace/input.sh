# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)
# privileged

PACKAGES=${REPO}/projects/ROCKNIX/packages
SYSUTILS=${PACKAGES}/sysutils/system-utils/sources
HOTPLUG=${PACKAGES}/rocknix/sources/scripts/handle-hdmi-hotplug
CFG=/storage/.config/system/configs/system.cfg
ACTIONS=/tmp/input.log
TOOLS="/usr/bin/volume /usr/bin/brightness /usr/bin/mako-notify /usr/bin/ledcontrol /usr/bin/wifictl
  /usr/bin/rocknix-fake-suspend /usr/bin/rocknix-screenshot /usr/bin/mangohud_set /usr/bin/game-guides-tool
  /usr/bin/rocknix-touchscreen /usr/bin/amixer /usr/bin/pactl /usr/bin/wlr-randr /usr/bin/systemctl"
PAD="KEY:Test Gamepad:BTN_SOUTH,BTN_EAST,BTN_NORTH,BTN_WEST,BTN_TL,BTN_TR,BTN_SELECT,BTN_START,BTN_MODE"
PAD="${PAD},BTN_DPAD_UP,BTN_DPAD_DOWN,BTN_DPAD_LEFT,BTN_DPAD_RIGHT,KEY_VOLUMEUP,KEY_VOLUMEDOWN"
JACK="SWITCH:Test Jack:SW_HEADPHONE_INSERT"

settings() {
  rm -rf /storage/.config
  mkdir -p "${CFG%/*}" /storage/.config/profile.d
  printf '%s\n' "$@" >"${CFG}"
}

setting() {
  sed -n "s/^$1=//p" "${CFG}"
}

profile() {
  printf '%s\n' "$@" >/storage/.config/profile.d/001-test
}

log_tools() {
  local t
  for t in "$@"; do
    stub "${t}" <<'EOF'
#!/bin/sh
echo "${0##*/}${*:+ $*}" >>/tmp/input.log
EOF
  done
  stub /usr/bin/mkcontroller <<'EOF'
#!/bin/sh
exit 0
EOF
}

actions() {
  cat "${ACTIONS}" 2>/dev/null
}

logged() {
  grep -qxF -- "$1" "${ACTIONS}" 2>/dev/null
}

until_true() {
  local n=0 limit=$1
  shift
  until if [ $# -eq 1 ]; then eval "$1"; else "$@"; fi; do
    [ ${n} -ge ${limit} ] && return 1
    n=$((n + 1))
    sleep 0.1
  done
}

wait_logged() {
  until_true 50 logged "$1" || fail "[$1] not seen, got:"$'\n'"$(actions)"$'\n'"$(cat daemon.log 2>/dev/null)"
}

alive() {
  local s
  s=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null) || return 1
  [ -n "${s}" ] && [ "${s%% *}" != Z ]
}

dead() {
  ! alive "$1"
}

group_alive() {
  cat /proc/[0-9]*/stat 2>/dev/null | awk -v g="$1" '{ sub(/.*\) /, ""); if ($3 == g && $1 != "Z") f = 1 } END { exit !f }'
}

uinput_helper() {
  cat >uinput.py <<'EOF'
import fcntl, os, struct, sys
KEYS = {"KEY_VOLUMEDOWN": 114, "KEY_VOLUMEUP": 115,
        "BTN_SOUTH": 304, "BTN_EAST": 305, "BTN_NORTH": 307, "BTN_WEST": 308, "BTN_TL": 310,
        "BTN_TR": 311, "BTN_SELECT": 314, "BTN_START": 315, "BTN_MODE": 316,
        "BTN_DPAD_UP": 544, "BTN_DPAD_DOWN": 545, "BTN_DPAD_LEFT": 546, "BTN_DPAD_RIGHT": 547}
SWITCHES = {"SW_HEADPHONE_INSERT": 2}
fds = []
for spec in sys.argv[1:]:
    kind, name, codes = spec.split(":")
    codes = codes.split(",")
    fd = os.open("/dev/uinput", os.O_WRONLY)
    if any(c in KEYS for c in codes):
        fcntl.ioctl(fd, 0x40045564, 1)
    if any(c in SWITCHES for c in codes):
        fcntl.ioctl(fd, 0x40045564, 5)
    for c in codes:
        if c in KEYS:
            fcntl.ioctl(fd, 0x40045565, KEYS[c])
        else:
            fcntl.ioctl(fd, 0x4004556d, SWITCHES[c])
    fcntl.ioctl(fd, 0x405c5503, struct.pack("HHHH80sI", 6, 0x1209, 0x0001, 1, name.encode(), 0))
    fcntl.ioctl(fd, 0x5501)
    buf = bytearray(64)
    fcntl.ioctl(fd, 0x8040552c, buf)
    print(buf.split(b"\0")[0].decode(), flush=True)
    fds.append(fd)
for line in iter(sys.stdin.readline, ""):
    index, code, value = line.split()
    kind, number = (5, SWITCHES[code]) if code in SWITCHES else (1, KEYS[code])
    os.write(fds[int(index)], struct.pack("llHHi", 0, 0, kind, number, int(value)))
    os.write(fds[int(index)], struct.pack("llHHi", 0, 0, 0, 0, 0))
EOF
}

uinput() {
  local spec sys ev dev i=0
  [ -c /dev/uinput ] || skip "no /dev/uinput in this container"
  uinput_helper
  mkfifo uinput.in
  python3 uinput.py "$@" <uinput.in >uinput.out 2>uinput.err &
  UINPUT=$!
  exec 3>uinput.in
  until_true 50 "[ \$(wc -l <uinput.out) -ge $# ]" || skip "cannot create uinput devices: $(cat uinput.err)"
  [ -d /dev/input ] || { mkdir /dev/input && MADE_DEV_INPUT=1; }
  mount -t tmpfs uinput /dev/input || fail "cannot mount a tmpfs on /dev/input"
  INPUT_MOUNTED=1
  mkdir -p /run/udev/data
  NODES=()
  while read -r sys; do
    i=$((i + 1))
    spec=${!i}
    until_true 20 "[ -e /sys/devices/virtual/input/${sys}/event*/dev ]" || fail "no event node for ${sys}"
    ev=$(echo /sys/devices/virtual/input/${sys}/event*)
    dev=$(cat "${ev}/dev")
    mknod "/dev/input/${ev##*/}" c "${dev%:*}" "${dev#*:}"
    (: <"/dev/input/${ev##*/}") 2>/dev/null || skip "cannot open ${ev##*/}, the device cgroup does not allow new input devices"
    printf 'I:1\nE:ID_INPUT=1\nE:ID_INPUT_%s=1\n' "${spec%%:*}" >"/run/udev/data/c${dev}"
    NODES+=("/dev/input/${ev##*/}")
  done <uinput.out
}

send() {
  echo "$*" >&3
}

tap() {
  send "$1" "$2" 1
  send "$1" "$2" 0
}

watching() {
  local p
  for p in $(pidof evtest); do
    ls -l "/proc/${p}/fd" 2>/dev/null | grep -q " $1\$" && return 0
  done
  return 1
}

start() {
  local n
  setsid bash "$1" </dev/null >daemon.log 2>&1 &
  DAEMON=$!
  shift
  for n in "$@"; do
    until_true 100 watching "${n}" || fail "${n} not opened:"$'\n'"$(cat daemon.log)"
  done
}

fake_evtest() {
  mkfifo events
  stub /usr/bin/evtest <<EOF
#!/bin/sh
exec 9<"\$1"
if [ "\$1" = "${NODES[0]}" ]; then cat "${PWD}/events"; else sleep 1000000; fi
EOF
  exec 4<>events
}

event() {
  echo "Event: time 0.000000, type $1, code $2, value $3" >&4
}

start_input_sense() {
  mknod /dev/input/event99 c 1 3
  printf 'I:1\nE:ID_INPUT=1\nE:ID_INPUT_JOYSTICK=1\n' >/run/udev/data/c1:3
  start "${SYSUTILS}/scripts/input_sense" "${NODES[@]}"
}

emu_helper() {
  cat >emu.py <<'EOF'
import signal, sys, time
log, mode = sys.argv[1], sys.argv[2]
def term(*_):
    with open(log, "a") as f:
        f.write("TERM\n")
    if mode == "exit":
        sys.exit(0)
signal.signal(signal.SIGTERM, term)
with open(log, "a") as f:
    f.write("ready\n")
while True:
    time.sleep(0.1)
EOF
}

emu() {
  emu_helper
  mkdir -p emu
  [ -e "emu/$1" ] || cp "$(readlink -f /usr/bin/python3)" "emu/$1"
  : >"$1.log"
  "emu/$1" emu.py "${PWD}/$1.log" "$2" &
  EMU=$!
  EMUS="${EMUS} ${EMU}"
  until_true 100 grep -q ready "$1.log" || fail "fake $1 did not start"
}

terminated() {
  grep -q TERM "$1.log"
}

kill_data() {
  (
    . "${PACKAGES}/rocknix/profile.d/001-functions" >/dev/null 2>&1
    set_kill set "$1"
  )
}

combo() {
  local b
  for b in "$@"; do send 0 "${b}" 1; done
}

release() {
  local b
  for b in "$@"; do send 0 "${b}" 0; done
}

hw_device() {
  (
    . /etc/os-release
    echo "${HW_DEVICE}"
  )
}

drm() {
  local c
  for c in "$@"; do
    mkdir -p "/sys/class/drm/card0/card0-${c%=*}"
    [ -e "/sys/class/drm/card0-${c%=*}" ] || ln -s "card0/card0-${c%=*}" "/sys/class/drm/card0-${c%=*}"
    echo "${c#*=}" >"/sys/class/drm/card0/card0-${c%=*}/status"
  done
}

cleanup() {
  local n=0
  if [ -n "${DAEMON}" ]; then
    kill -TERM -- -${DAEMON} 2>/dev/null
    while group_alive ${DAEMON} && [ ${n} -lt 50 ]; do
      sleep 0.1
      n=$((n + 1))
    done
    kill -KILL -- -${DAEMON} 2>/dev/null
  fi
  [ -n "${EMUS}" ] && kill -KILL ${EMUS} 2>/dev/null
  [ -n "${RUNEMU}" ] && kill -KILL ${RUNEMU} 2>/dev/null
  if [ -n "${UINPUT}" ]; then
    exec 3>&-
    kill ${UINPUT} 2>/dev/null
    wait ${UINPUT} 2>/dev/null
  fi
  if [ -n "${INPUT_MOUNTED}" ]; then
    n=0
    until umount /dev/input 2>/dev/null || [ ${n} -ge 50 ]; do
      sleep 0.1
      n=$((n + 1))
    done
  fi
  [ -n "${MADE_DEV_INPUT}" ] && rmdir /dev/input
  [ -n "${FAKE_CLASS}" ] && umount /sys/class
  rm -rf /run/udev /storage/.config /tmp/input.log /tmp/.process-kill-data /run/hdmi-status.last /tmp/outputs
  unstub ${TOOLS} /usr/bin/mkcontroller /usr/bin/pgrep /usr/bin/evtest
}

test_input_sense_volume_keys() {
  trap cleanup EXIT
  settings audio.volume=50 display.brightness=40
  log_tools ${TOOLS}
  uinput "${PAD}"
  start_input_sense
  tap 0 KEY_VOLUMEUP
  tap 0 KEY_VOLUMEDOWN
  until_true 50 '[ "$(grep -c mako-notify "${ACTIONS}" 2>/dev/null)" -ge 2 ]'
  assert_eq "$(uniq "${ACTIONS}")" "volume up
mako-notify Volume: 50% -no-es
volume down
mako-notify Volume: 50% -no-es" "volume key taps"
}

test_input_sense_volume_repeats_while_held() {
  local held after
  trap cleanup EXIT
  settings audio.volume=50
  log_tools ${TOOLS}
  uinput "${PAD}"
  start_input_sense
  send 0 KEY_VOLUMEDOWN 1
  sleep 1.5
  send 0 KEY_VOLUMEDOWN 0
  wait_logged "mako-notify Volume: 50% -no-es"
  held=$(grep -c '^volume down$' "${ACTIONS}")
  [ "${held}" -ge 3 ] || fail "only ${held} volume steps while held for 1.5 s"
  sleep 1
  after=$(grep -c '^volume down$' "${ACTIONS}")
  assert_eq "${after}" "${held}" "volume steps after release"
}

test_input_sense_function_modifier_actions() {
  trap cleanup EXIT
  settings audio.volume=50 display.brightness=40
  profile 'DEVICE_FUNC_KEYA_MODIFIER="BTN_MODE"' 'DEVICE_FUNC_KEYB_MODIFIER="BTN_START"'
  log_tools ${TOOLS}
  uinput "${PAD}"
  start_input_sense
  send 0 BTN_MODE 1
  tap 0 KEY_VOLUMEUP
  tap 0 KEY_VOLUMEDOWN
  send 0 BTN_MODE 0
  send 0 BTN_START 1
  tap 0 KEY_VOLUMEUP
  tap 0 KEY_VOLUMEDOWN
  send 0 BTN_MODE 1
  tap 0 KEY_VOLUMEUP
  tap 0 KEY_VOLUMEDOWN
  release BTN_MODE BTN_START
  wait_logged "wifictl disable"
  assert_eq "$(actions)" "brightness up
mako-notify Brightness: 40% -no-es
brightness down
mako-notify Brightness: 40% -no-es
ledcontrol
ledcontrol poweroff
wifictl enable
wifictl disable" "modifier actions"
}

test_input_sense_function_settings_override_quirks() {
  trap cleanup EXIT
  settings audio.volume=50 key.function.a=BTN_TR "key.function.a.up=ledcontrol red" "key.function.a.down=ledcontrol off"
  profile 'DEVICE_FUNC_KEYA_MODIFIER="BTN_MODE"'
  log_tools ${TOOLS}
  uinput "${PAD}"
  start_input_sense
  send 0 BTN_MODE 1
  tap 0 KEY_VOLUMEUP
  send 0 BTN_MODE 0
  send 0 BTN_TR 1
  tap 0 KEY_VOLUMEUP
  tap 0 KEY_VOLUMEDOWN
  send 0 BTN_TR 0
  wait_logged "ledcontrol off"
  assert_eq "$(uniq "${ACTIONS}")" "volume up
mako-notify Volume: 50% -no-es
ledcontrol red
ledcontrol off" "key.function.a from system.cfg"
}

test_input_sense_dpad_hotkeys() {
  trap cleanup EXIT
  settings audio.volume=50 display.brightness=40 key.dpad.events=1
  profile 'DEVICE_FUNC_KEYA_MODIFIER="BTN_MODE"'
  log_tools ${TOOLS}
  uinput "${PAD}"
  start_input_sense
  tap 0 BTN_DPAD_UP
  send 0 BTN_MODE 1
  tap 0 BTN_DPAD_UP
  tap 0 BTN_DPAD_DOWN
  tap 0 BTN_DPAD_RIGHT
  tap 0 BTN_DPAD_LEFT
  send 0 BTN_MODE 0
  until_true 50 '[ "$(grep -c mako-notify "${ACTIONS}" 2>/dev/null)" -ge 2 ]'
  assert_eq "$(actions)" "volume up
volume down
brightness up
mako-notify Brightness: 40% -no-es
brightness down
mako-notify Brightness: 40% -no-es" "dpad with function key"
}

test_input_sense_hotkey_tools() {
  trap cleanup EXIT
  settings
  profile 'DEVICE_HAS_TOUCHSCREEN="true"'
  log_tools ${TOOLS}
  uinput "${PAD}"
  start_input_sense
  tap 0 BTN_EAST
  send 0 BTN_TL 1
  tap 0 BTN_EAST
  tap 0 BTN_WEST
  tap 0 BTN_NORTH
  tap 0 BTN_SOUTH
  send 0 BTN_SELECT 1
  tap 0 BTN_SOUTH
  release BTN_SELECT BTN_TL
  wait_logged "mako-notify Touchscreen toggled -no-es"
  assert_eq "$(actions)" "rocknix-screenshot
mako-notify Screenshot Saved -no-ra
mangohud_set toggle
game-guides-tool
rocknix-touchscreen toggle
mako-notify Touchscreen toggled -no-es" "hotkey tools"
}

test_input_sense_power_key_and_lid() {
  trap cleanup EXIT
  settings
  log_tools ${TOOLS}
  uinput "${PAD}"
  fake_evtest
  start_input_sense
  event "1 (EV_KEY)" "116 (KEY_POWER)" 1
  event "1 (EV_KEY)" "116 (KEY_POWER)" 0
  wait_logged "rocknix-fake-suspend power"
  event "5 (EV_SW)" "0 (SW_LID)" 1
  wait_logged "rocknix-fake-suspend lid close"
  event "5 (EV_SW)" "0 (SW_LID)" 0
  wait_logged "rocknix-fake-suspend lid open"
  sleep 0.5
  assert_eq "$(actions)" "rocknix-fake-suspend power
rocknix-fake-suspend lid close
rocknix-fake-suspend lid open" "power key and lid"
}

test_input_sense_quit_combo_in_any_order() {
  local order
  trap cleanup EXIT
  settings
  log_tools ${TOOLS}
  uinput "${PAD}"
  kill_data fakeemu
  start_input_sense
  emu fakeemu exit
  combo BTN_TL BTN_SELECT
  sleep 1
  terminated fakeemu && fail "L1 + Select quit the game"
  release BTN_TL BTN_SELECT
  combo BTN_START BTN_SELECT
  sleep 1
  terminated fakeemu && fail "Start + Select quit the game"
  release BTN_START BTN_SELECT
  for order in "BTN_TL BTN_SELECT BTN_START" "BTN_TL BTN_START BTN_SELECT" "BTN_SELECT BTN_START BTN_TL" \
    "BTN_START BTN_SELECT BTN_TL"; do
    alive ${EMU} || emu fakeemu exit
    combo ${order}
    until_true 50 terminated fakeemu || fail "${order} did not quit the game"
    release ${order}
    until_true 50 dead ${EMU} || fail "game still running after ${order}"
  done
}

test_input_sense_quit_combo_falls_back_to_runemu_children() {
  local data
  trap cleanup EXIT
  settings
  log_tools ${TOOLS}
  uinput "${PAD}"
  emu_helper
  mkdir -p emu
  cp "$(readlink -f /usr/bin/python3)" emu/fakeemu
  cat >emu/runemu.sh <<EOF
#!/bin/bash
trap 'echo TERM >>"${PWD}/runemu.log"' TERM
"${PWD}/emu/fakeemu" "${PWD}/emu.py" "${PWD}/fakeemu.log" exit
echo done >>"${PWD}/runemu.log"
EOF
  chmod 755 emu/runemu.sh
  start_input_sense
  for data in "" absentemu; do
    rm -f /tmp/.process-kill-data fakeemu.log runemu.log
    [ -n "${data}" ] && kill_data "${data}"
    emu/runemu.sh &
    RUNEMU=$!
    until_true 100 grep -q ready fakeemu.log 2>/dev/null || fail "fake game did not start"
    combo BTN_TL BTN_SELECT BTN_START
    until_true 50 terminated fakeemu || fail "kill data [${data}]: game started by runemu.sh not quit"
    release BTN_TL BTN_SELECT BTN_START
    until_true 50 grep -q done runemu.log || fail "runemu.sh did not finish"
    assert_eq "$(cat runemu.log)" "done" "kill data [${data}]: runemu.sh signalled"
  done
}

test_input_sense_quit_combo_force_kills_hung_game() {
  trap cleanup EXIT
  settings
  log_tools ${TOOLS}
  uinput "${PAD}"
  kill_data fakeemu
  start_input_sense
  emu fakeemu ignore
  combo BTN_TL BTN_SELECT BTN_START
  until_true 50 terminated fakeemu || fail "hung game got no SIGTERM"
  release BTN_TL BTN_SELECT BTN_START
  sleep 2
  alive ${EMU} || fail "hung game killed before the grace period"
  until_true 80 dead ${EMU} || fail "hung game still running 10 s after the quit combo"
}

test_input_sense_quit_combo_kill_data_signal() {
  trap cleanup EXIT
  settings
  log_tools ${TOOLS}
  uinput "${PAD}"
  kill_data "-9 fakeemu"
  start_input_sense
  emu fakeemu exit
  combo BTN_TL BTN_SELECT BTN_START
  until_true 30 dead ${EMU} || fail "game not killed by -9 kill data"
  terminated fakeemu && fail "game got SIGTERM instead of SIGKILL"
  return 0
}

test_input_sense_quit_combo_never_forces_emulationstation() {
  trap cleanup EXIT
  settings
  log_tools ${TOOLS}
  uinput "${PAD}"
  kill_data emulationstation
  start_input_sense
  emu emulationstation ignore
  combo BTN_TL BTN_SELECT BTN_START
  until_true 50 terminated emulationstation || fail "EmulationStation got no SIGTERM"
  release BTN_TL BTN_SELECT BTN_START
  sleep 6.5
  alive ${EMU} || fail "EmulationStation was force killed"
}

headphone_sense() {
  local script=${SYSUTILS}/devices/$(hw_device)/headphone_sense
  [ -e "${script}" ] || script=${SYSUTILS}/scripts/headphone_sense
  echo "${script}"
}

headphone_setup() {
  settings audio.volume=50
  log_tools ${TOOLS}
  stub /usr/bin/amixer <<'EOF'
#!/bin/sh
{ printf amixer; printf '|%s' "$@"; echo; } >>/tmp/input.log
EOF
  uinput "${JACK}"
  profile "DEVICE_HEADPHONE_DEV=\"${NODES[0]}\"" 'DEVICE_JACK="86"' 'ALSA_PRIMARY_CARD=1' \
    'DEVICE_PLAYBACK_PATH="Playback Mux"' 'DEVICE_PLAYBACK_PATH_HP="HP"' 'DEVICE_PLAYBACK_PATH_SPK="SPK"'
  mount -t tmpfs fake /sys/class || fail "cannot mount a tmpfs on /sys/class"
  FAKE_CLASS=1
  mkdir -p /sys/class/gpio/gpio86
  echo "$1" >/sys/class/gpio/gpio86/value
  start "$(headphone_sense)" "${NODES[0]}"
}

mixer() {
  grep '^amixer|' "${ACTIONS}" 2>/dev/null
}

test_headphone_sense_follows_jack_switch() {
  trap cleanup EXIT
  headphone_setup 1
  assert_eq "$(setting audio.device)" "speakers" "audio.device at boot without headphones"
  : >"${ACTIONS}"
  send 0 SW_HEADPHONE_INSERT 1
  until_true 50 '[ -n "$(mixer)" ]' || fail "no mixer change on jack event"
  assert_eq "$(setting audio.device)" "speakers" "audio.device after SW_HEADPHONE_INSERT 1"
  assert_eq "$(mixer | sed 's/.*|//')" "SPK" "playback path after SW_HEADPHONE_INSERT 1"
  : >"${ACTIONS}"
  send 0 SW_HEADPHONE_INSERT 0
  until_true 50 '[ "$(setting audio.device)" = headphone ]'
  assert_eq "$(setting audio.device)" "headphone" "audio.device after SW_HEADPHONE_INSERT 0"
  assert_eq "$(mixer | sed 's/.*|//')" "HP" "playback path after SW_HEADPHONE_INSERT 0"
}

test_headphone_sense_mixer_control_name() {
  local line
  trap cleanup EXIT
  headphone_setup 1
  send 0 SW_HEADPHONE_INSERT 1
  until_true 50 '[ "$(mixer | wc -l)" -ge 2 ]' || fail "no mixer change on jack event"
  while read -r line; do
    assert_contains "${line}" "|cset|name=Playback Mux|" "amixer arguments"
  done <<EOF
$(mixer)
EOF
}

test_headphone_sense_boot_with_headphones() {
  trap cleanup EXIT
  headphone_setup 0
  assert_eq "$(setting audio.device)" "headphone" "audio.device at boot with headphones"
  assert_eq "$(mixer | head -n 1 | sed 's/.*|//')" "HP" "playback path at boot with headphones"
}

test_headphone_sense_ucm_restores_volume() {
  trap cleanup EXIT
  settings audio.volume=50
  log_tools ${TOOLS}
  profile 'AUDIO_MANAGEMENT=UCM'
  timeout 10 bash "$(headphone_sense)" </dev/null >/dev/null 2>&1 || fail "headphone_sense exited with $?"
  assert_eq "$(actions)" "volume restore" "UCM devices only restore the volume"
}

pactl_stub() {
  stub /usr/bin/pactl <<'EOF'
#!/bin/sh
case "$*" in
  "list short sinks")
    printf '55\talsa_output.platform-sound.HiFi__Speaker__sink\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n'
    printf '62\talsa_output.platform-hdmi-sound.HiFi__HDMI__sink\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n'
    ;;
  "list short cards")
    printf '48\talsa_card.platform-sound\talsa\n49\talsa_card.platform-hdmi-sound\talsa\n'
    ;;
  *) echo "pactl $*" >>/tmp/input.log ;;
esac
EOF
}

test_hdmi_sense_records_state_and_sink() {
  local speaker=alsa_output.platform-sound.HiFi__Speaker__sink before
  trap cleanup EXIT
  settings
  profile 'DEVICE_PIPEWIRE_PROFILE="HiFi"'
  log_tools ${TOOLS}
  pactl_stub
  mount -t tmpfs fake /sys/class || fail "cannot mount a tmpfs on /sys/class"
  FAKE_CLASS=1
  rm -f /run/hdmi-status.last
  drm HDMI-A-1=connected DP-1=disconnected
  bash "${SYSUTILS}/scripts/hdmi_sense" </dev/null >/dev/null 2>&1
  assert_eq "$(cat /run/hdmi-status.last)" "connected" "state with HDMI connected"
  assert_eq "$(actions)" "pactl set-default-sink alsa_output.platform-hdmi-sound.HiFi__HDMI__sink" "HDMI sink"
  rm -f "${ACTIONS}"
  drm HDMI-A-1=disconnected
  bash "${SYSUTILS}/scripts/hdmi_sense" </dev/null >/dev/null 2>&1
  assert_eq "$(cat /run/hdmi-status.last)" "disconnected" "state with HDMI disconnected"
  assert_eq "$(actions)" "pactl set-default-sink ${speaker}
pactl set-default-source ${speaker}.monitor
pactl set-card-profile 48 HiFi
pactl set-default-sink ${speaker}" "speaker sink and card profile"
  touch -t 200001010000 /run/hdmi-status.last
  before=$(stat -c %Y /run/hdmi-status.last)
  bash "${SYSUTILS}/scripts/hdmi_sense" </dev/null >/dev/null 2>&1
  assert_eq "$(stat -c %Y /run/hdmi-status.last)" "${before}" "status file rewritten for an unchanged state"
  drm DP-1=connected
  bash "${SYSUTILS}/scripts/hdmi_sense" </dev/null >/dev/null 2>&1
  assert_eq "$(cat /run/hdmi-status.last)" "connected" "state with DisplayPort connected"
}

test_hdmi_hotplug_switches_outputs() {
  trap cleanup EXIT
  settings
  log_tools ${TOOLS}
  pactl_stub
  stub /usr/bin/wlr-randr <<'EOF'
#!/bin/sh
if [ $# -eq 0 ]; then cat /tmp/outputs; else echo "wlr-randr $*" >>/tmp/input.log; fi
EOF
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
[ "$1" = is-active ] && exit 0
echo "systemctl $*" >>/tmp/input.log
EOF
  stub /usr/bin/pgrep <<'EOF'
#!/bin/sh
[ "$*" = "-x emulationstation" ] && exit 0
exec /.stubs/orig/usr/bin/pgrep "$@"
EOF
  mount -t tmpfs fake /sys/class || fail "cannot mount a tmpfs on /sys/class"
  FAKE_CLASS=1
  rm -f /run/hdmi-status.last
  printf 'HDMI-A-1 "TV"\n  Enabled: no\nDSI-1 "Panel"\n  Enabled: yes\n' >/tmp/outputs
  drm HDMI-A-1=connected DP-1=disconnected
  emu emulationstation exit
  bash "${SYSUTILS}/scripts/hdmi_sense" </dev/null >/dev/null 2>&1
  sh "${HOTPLUG}" </dev/null >/dev/null 2>&1
  until_true 50 terminated emulationstation || fail "EmulationStation not restarted on HDMI connect"
  assert_eq "$(actions | grep -v '^pactl')" "wlr-randr --output HDMI-A-1 --preferred --on
wlr-randr --output DSI-1 --off" "outputs on HDMI connect"
  until_true 50 dead ${EMU}
  rm -f "${ACTIONS}"
  drm HDMI-A-1=disconnected
  emu emulationstation exit
  bash "${SYSUTILS}/scripts/hdmi_sense" </dev/null >/dev/null 2>&1
  sh "${HOTPLUG}" </dev/null >/dev/null 2>&1
  until_true 50 terminated emulationstation || fail "EmulationStation not restarted on HDMI disconnect"
  assert_eq "$(actions | grep -v '^pactl')" "wlr-randr --output DSI-1 --preferred --on" "outputs on HDMI disconnect"
  until_true 50 dead ${EMU}
  rm -f "${ACTIONS}"
  printf 'DP-1 "Dock"\n  Enabled: no\nDSI-1 "Panel"\n  Enabled: yes\n' >/tmp/outputs
  drm DP-1=connected
  emu emulationstation exit
  bash "${SYSUTILS}/scripts/hdmi_sense" </dev/null >/dev/null 2>&1
  sh "${HOTPLUG}" </dev/null >/dev/null 2>&1
  until_true 50 terminated emulationstation || fail "EmulationStation not restarted on DisplayPort connect"
  assert_eq "$(actions | grep -v '^pactl')" "systemctl stop usbgadget
wlr-randr --output DP-1 --preferred --on
wlr-randr --output DSI-1 --off" "outputs on DisplayPort connect"
}
