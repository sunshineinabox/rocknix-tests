# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)
# privileged

PACKAGES=${REPO}/projects/ROCKNIX/packages
MONITOR=${PACKAGES}/sysutils/system-utils/sources/scripts/output_monitor
HDMI_CHECK=${PACKAGES}/rocknix/autostart/055-hdmi-check
SWAY=${PACKAGES}/wayland/compositor/sway
QUIRKS=${PACKAGES}/hardware/quirks
CFG=/storage/.config/system/configs/system.cfg
SWAY_CONFIG=/storage/.config/sway/config
SWAY_ENV=/storage/.config/profile.d/095-sway
TOOLS="/usr/bin/wlr-randr /usr/bin/swaymsg /usr/bin/wpctl /usr/bin/pw-cli /usr/bin/systemctl /usr/bin/modetest
  /usr/bin/drm_tool /usr/sbin/fbset /usr/share/sway/config.kiosk /usr/share/sway/config.desktop"
SHELL_ERRORS='command not found|syntax error|unary operator expected|integer expression expected|too many arguments|bad substitution|ambiguous redirect'
ES='[app_id="emulationstation"]'

until_true() {
  local n=0 limit=$1
  shift
  until if [ $# -eq 1 ]; then eval "$1"; else "$@"; fi; do
    [ ${n} -ge ${limit} ] && return 1
    n=$((n + 1))
    sleep 0.1
  done
}

settings() {
  rm -rf /storage/.config
  mkdir -p "${CFG%/*}" /storage/.config/profile.d
  printf '%s\n' "$@" >"${CFG}"
}

setting() {
  sed -n "s/^$1=//p" "${CFG}"
}

stubs() {
  stub /usr/bin/wlr-randr <<'EOF'
#!/bin/sh
if [ $# -eq 0 ]; then
  cat "${FAKE}/outputs" 2>/dev/null
  exit 0
fi
echo "wlr-randr $*" >>"${FAKE}/actions"
case "$*" in *@60*) [ ! -e "${FAKE}/no60" ] ;; esac
EOF
  stub /usr/bin/swaymsg <<'EOF'
#!/bin/sh
if [ "$1 $2" = "-t subscribe" ]; then
  echo "$3" >>"${FAKE}/subscribed"
  while [ ! -e "${FAKE}/stop" ]; do
    if mv "${FAKE}/event" "${FAKE}/event.done" 2>/dev/null; then
      echo '{ "change": "unspecified" }'
      exit 0
    fi
    sleep 0.05
  done
  exit 1
fi
echo "swaymsg $*" >>"${FAKE}/actions"
EOF
  stub /usr/bin/wpctl <<'EOF'
#!/bin/sh
if [ "$1" != status ]; then
  echo "wpctl $*" >>"${FAKE}/actions"
  exit 0
fi
card=$(cat "${FAKE}/card" 2>/dev/null)
cat <<STATUS
PipeWire 'pipewire-0' [1.4.7, root@ROCKNIX, cookie:3735928559]
 └─ Clients:
        33. WirePlumber                         [1.4.7, root@ROCKNIX, pid:612]
        47. wpctl                               [1.4.7, root@ROCKNIX, pid:1201]

Audio
 ├─ Devices:
STATUS
[ -n "${card}" ] && printf ' │      %s. Built-in Audio                      [alsa]\n' "${card}"
cat <<STATUS
 │      70. Pixel Buds                          [bluez5]
 │
 ├─ Sinks:
 │  *   55. Built-in Audio Speaker              [vol: 0.50]
 │
 ├─ Sources:
 │
 ├─ Filters:
 │
 └─ Streams:

Video
 ├─ Devices:
 │      40. platform-aa00000.video-codec        [v4l2]
 │
 ├─ Sinks:
 │
 ├─ Sources:
 │
 ├─ Filters:
 │
 └─ Streams:

Settings
 └─ Default Configured Devices:
         0. Audio/Sink    alsa_output.platform-sound.HiFi__Speaker__sink
STATUS
EOF
  stub /usr/bin/pw-cli <<'EOF'
#!/bin/sh
[ "$1 $3" = "enum-params EnumProfile" ] && [ "$2" = "$(cat "${FAKE}/card" 2>/dev/null)" ] || exit 0
for p in $(cat "${FAKE}/profiles"); do
  echo '  Object: size 1248, type Spa:Pod:Object:Param:Profile (262145), id Spa:Enum:ParamId:EnumProfile (8)'
  printf '    Prop: key Spa:Pod:Object:Param:Profile:index (1), flags 00000000\n      Int %s\n' "${p%%:*}"
  printf '    Prop: key Spa:Pod:Object:Param:Profile:name (2), flags 00000000\n      String "%s"\n' "${p#*:}"
  printf '    Prop: key Spa:Pod:Object:Param:Profile:description (3), flags 00000000\n      String "%s"\n' "${p#*:} output"
  printf '    Prop: key Spa:Pod:Object:Param:Profile:priority (4), flags 00000000\n      Int 100\n'
  printf '    Prop: key Spa:Pod:Object:Param:Profile:available (5), flags 00000000\n      Id 1 (Spa:Enum:ParamAvailability:yes)\n'
done
EOF
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
case "$*" in
  "is-active --quiet usbgadget") [ -e "${FAKE}/usbgadget" ]; exit ;;
  "is-enabled essway.service") cat "${FAKE}/essway" 2>/dev/null; exit 0 ;;
esac
echo "systemctl $*" >>"${FAKE}/actions"
case "$*" in
  "stop usbgadget") rm -f "${FAKE}/usbgadget" ;;
  "restart wireplumber")
    if [ -e "${FAKE}/restart" ]; then
      read -r card profiles <"${FAKE}/restart"
      echo "${card}" >"${FAKE}/card"
      echo "${profiles}" >"${FAKE}/profiles"
      rm -f "${FAKE}/restart"
    fi
    ;;
esac
exit 0
EOF
  stub /usr/bin/modetest <<'EOF'
#!/bin/sh
echo "Connectors:"
printf 'id\tencoder\tstatus\t\tname\t\tsize (mm)\tmodes\tencoders\n'
id=31
for c in /sys/class/drm/card*-*; do
  [ -e "${c}/status" ] || continue
  printf '%s\t%s\t%s\t%s\t0x0\t\t1\t%s\n' ${id} $((id - 1)) "$(cat "${c}/status")" "${c##*/card?-}" $((id - 1))
  id=$((id + 2))
done
EOF
  stub /usr/bin/drm_tool <<'EOF'
#!/bin/sh
[ "$1" = list ] || exit 1
cat <<LIST
Card /dev/dri/card0
  Connector: 33
    mode  0: 3840x2160       30Hz 3840x2160
    mode  1: 1920x1080       50Hz 1920x1080
    mode  2: 1920x1080       60Hz 1920x1080
    mode  3: 1920x1080       30Hz 1920x1080
    mode  4: 1280x720        50Hz 1280x720
    mode  5: 1280x720        60Hz 1280x720
    mode  6: 720x480         60Hz 720x480
LIST
EOF
  stub /usr/sbin/fbset <<'EOF'
#!/bin/sh
read -r w h <"${FAKE}/fb"
printf '\nmode "%sx%s"\n    geometry %s %s %s %s 32\n    timings 0 0 0 0 0 0 0\n    rgba 8/16,8/8,8/0,0/0\nendmode\n\n' \
  ${w} ${h} ${w} ${h} ${w} ${h}
EOF
  stub /usr/share/sway/config.kiosk <"${SWAY}/config/config.kiosk"
  stub /usr/share/sway/config.desktop <"${SWAY}/config/config.desktop"
}

setup() {
  local m
  trap cleanup EXIT
  export FAKE=${PWD}
  for m in /sys/class /sys/devices/virtual /sys/firmware; do
    mount -t tmpfs fake "${m}" || fail "cannot mount a tmpfs on ${m}"
    MOUNTS="${m} ${MOUNTS}"
  done
  mkdir -p /sys/devices/virtual/graphics/fbcon /sys/class/graphics /sys/class/drm /sys/firmware/devicetree/base
  ln -s ../../devices/virtual/graphics/fbcon /sys/class/graphics/fbcon
  echo 0 >/sys/devices/virtual/graphics/fbcon/rotate
  echo 1080 1920 >fb
  echo enabled >essway
  [ -e /var/run ] || { ln -s /run /var/run && VAR_RUN=1; }
  settings
  stubs
}

cleanup() {
  local m
  touch "${FAKE}/stop"
  if [ -n "${DAEMON}" ]; then
    kill -TERM -- -${DAEMON} 2>/dev/null
    wait ${DAEMON} 2>/dev/null
  fi
  for m in ${MOUNTS}; do umount "${m}"; done
  [ -n "${VAR_RUN}" ] && rm -f /var/run
  rm -rf /storage/.config /run/drmMode /run/drmConn
  unstub ${TOOLS}
}

edid() {
  printf '\0\377\377\377\377\377\377\0%s\n' "$1"
  head -c 100 /dev/zero
}

drm() {
  local c card name dir
  for c in "$@"; do
    card=card0
    case "${c}" in */*) card=${c%%/*} c=${c#*/} ;; esac
    name=${c%%=*}
    c=${c#*=}
    dir=/sys/class/drm/${card}/${card}-${name}
    mkdir -p "${dir}"
    [ -e "/sys/class/drm/${card}-${name}" ] || ln -s "${card}/${card}-${name}" "/sys/class/drm/${card}-${name}"
    echo "${c%%,*}" >"${dir}/status"
    case "${c}" in
      *,*) edid "${c#*,}" >"${dir}/edid" ;;
      *) : >"${dir}/edid" ;;
    esac
  done
}

actions() {
  cat "${FAKE}/actions" 2>/dev/null
}

logged() {
  grep -qxF -- "$1" "${FAKE}/actions" 2>/dev/null
}

outputs() {
  local o
  for o in "$@"; do
    printf '%s "Test %s"\n  Make: Test\n  Model: %s\n  Serial: (null)\n  Physical size: 70x120 mm\n  Enabled: %s\n' \
      "${o%=*}" "${o%=*}" "${o%=*}" "${o#*=}"
    printf '  Modes:\n    1920x1080 px, 60.000000 Hz (preferred, current)\n    1280x720 px, 60.000000 Hz\n'
    printf '  Position: 0,0\n  Transform: normal\n  Scale: 1.000000\n  Adaptive Sync: disabled\n'
  done >"${FAKE}/outputs.new"
  mv "${FAKE}/outputs.new" "${FAKE}/outputs"
}

audio() {
  echo "$1" >"${FAKE}/card"
  echo "$2" >"${FAKE}/profiles"
}

subscriptions() {
  cat "${FAKE}/subscribed" 2>/dev/null | wc -l
}

start_monitor() {
  setsid bash "${MONITOR}" </dev/null >monitor.log 2>&1 &
  DAEMON=$!
  until_true 100 '[ $(subscriptions) -ge 1 ]' || fail "output_monitor did not subscribe to output events:"$'\n'"$(cat monitor.log)"
}

event() {
  local n
  n=$(subscriptions)
  touch "${FAKE}/event"
  until_true 150 "[ \$(subscriptions) -gt ${n} ]" || fail "output event not handled:"$'\n'"$(cat monitor.log)"
}

panel_off_and_on() {
  setup
  drm DSI-1=connected "$1=disconnected"
  audio 48 "0:off 2:HiFi 5:HDMI"
  outputs DSI-1=yes
  start_monitor
  assert_eq "$(actions)" "" "actions at boot without an external display"
  outputs DSI-1=yes "$1=yes"
  event
  assert_eq "$(grep -E '^(wlr-randr|swaymsg)' "${FAKE}/actions")" "wlr-randr --output DSI-1 --off
wlr-randr --output $1 --mode 1920x1080@60
swaymsg ${ES} move output $1" "$1 enabled"
  : >"${FAKE}/actions"
  outputs DSI-1=no
  event
  assert_eq "$(grep -E '^(wlr-randr|swaymsg)' "${FAKE}/actions")" "wlr-randr --output DSI-1 --preferred --on" "$1 removed"
}

test_output_monitor_exits_without_external_connectors() {
  local rc
  setup
  drm DSI-1=connected
  outputs DSI-1=yes
  timeout 2 bash "${MONITOR}" </dev/null >monitor.log 2>&1
  rc=$?
  assert_eq "${rc}" "0" "exit status without DP or HDMI connectors"
  assert_eq "$(actions)$(subscriptions)" "0" "actions and subscriptions without DP or HDMI connectors"
}

test_output_monitor_hdmi_turns_panel_off_and_on() {
  panel_off_and_on HDMI-A-1
}

test_output_monitor_dp_turns_panel_off_and_on() {
  panel_off_and_on DP-1
}

test_output_monitor_switches_audio_profile() {
  setup
  drm DSI-1=connected HDMI-A-1=disconnected
  audio 52 "0:off 2:HiFi 5:HDMI"
  outputs DSI-1=yes
  start_monitor
  outputs DSI-1=yes HDMI-A-1=yes
  event
  assert_eq "$(grep -E '^(wpctl|systemctl)' "${FAKE}/actions")" "wpctl set-profile 52 5" "audio on HDMI connect"
  : >"${FAKE}/actions"
  outputs DSI-1=no
  event
  assert_eq "$(grep -E '^(wpctl|systemctl)' "${FAKE}/actions")" "wpctl set-profile 52 2" "audio on HDMI disconnect"
  : >"${FAKE}/actions"
  audio "" ""
  outputs DSI-1=no HDMI-A-1=yes
  event
  assert_eq "$(grep -E '^(wpctl|systemctl)' "${FAKE}/actions")" "" "audio actions without an ALSA card"
  logged "wlr-randr --output DSI-1 --off" || fail "panel left on without an ALSA card:"$'\n'"$(actions)"
}

test_output_monitor_restarts_wireplumber_for_hdmi_profile() {
  setup
  drm DSI-1=connected HDMI-A-1=disconnected
  audio 48 "0:off 2:HiFi"
  echo "61 0:off 2:HiFi 5:HDMI" >restart
  outputs DSI-1=yes
  start_monitor
  outputs DSI-1=yes HDMI-A-1=yes
  event
  assert_eq "$(grep -E '^(wpctl|systemctl)' "${FAKE}/actions")" "systemctl restart wireplumber
wpctl set-profile 61 5" "audio when the HDMI profile appears after a WirePlumber restart"
}

test_output_monitor_ignores_unchanged_state() {
  setup
  drm DSI-1=connected HDMI-A-1=connected
  audio 48 "0:off 2:HiFi 5:HDMI"
  outputs DSI-1=yes HDMI-A-1=no
  start_monitor
  event
  event
  assert_eq "$(actions)" "" "actions with the external output disabled"
  outputs DSI-1=yes HDMI-A-1=yes
  event
  logged "wlr-randr --output DSI-1 --off" || fail "panel not turned off:"$'\n'"$(actions)"
  : >"${FAKE}/actions"
  outputs DSI-1=no HDMI-A-1=yes
  event
  event
  event
  assert_eq "$(actions)" "" "actions while the external output stays enabled"
  outputs DSI-1=no
  event
  logged "wlr-randr --output DSI-1 --preferred --on" || fail "panel not turned on:"$'\n'"$(actions)"
  : >"${FAKE}/actions"
  outputs DSI-1=yes
  event
  event
  assert_eq "$(actions)" "" "actions after the external output went away"
}

test_output_monitor_external_at_boot() {
  setup
  drm DSI-1=connected HDMI-A-1=connected
  audio 48 "0:off 2:HiFi 5:HDMI"
  touch no60
  outputs DSI-1=yes HDMI-A-1=yes
  start_monitor
  assert_eq "$(actions)" "wlr-randr --output DSI-1 --off
wlr-randr --output HDMI-A-1 --mode 1920x1080@60
wlr-randr --output HDMI-A-1 --mode 1920x1080
swaymsg ${ES} move output HDMI-A-1
wpctl set-profile 48 5" "actions at boot with HDMI enabled and no 60 Hz 1080p mode"
  : >"${FAKE}/actions"
  outputs DSI-1=no
  event
  assert_eq "$(actions)" "wlr-randr --output DSI-1 --preferred --on
wpctl set-profile 48 2" "actions when HDMI goes away after boot"
}

test_output_monitor_multiple_panels_and_usb_gadget() {
  setup
  drm DSI-1=connected DSI-2=connected HDMI-A-1=disconnected DP-1=disconnected
  audio 48 "0:off 2:HiFi 5:HDMI"
  touch usbgadget
  outputs DSI-1=yes DSI-2=yes HDMI-A-1=no
  start_monitor
  outputs DSI-1=yes DSI-2=yes HDMI-A-1=no DP-1=yes
  event
  assert_eq "$(actions)" "wlr-randr --output DSI-1 --off
wlr-randr --output DSI-2 --off
wlr-randr --output DP-1 --mode 1920x1080@60
swaymsg ${ES} move output DP-1
systemctl stop usbgadget
wpctl set-profile 48 5" "actions when DP-1 appears"
  : >"${FAKE}/actions"
  outputs DSI-1=no DSI-2=no HDMI-A-1=no
  event
  assert_eq "$(actions)" "wlr-randr --output DSI-1 --preferred --on
wlr-randr --output DSI-2 --preferred --on
wpctl set-profile 48 2" "actions when DP-1 goes away"
}

fb_modes() {
  mkdir -p /sys/class/graphics/fb0
  echo "$1" >/sys/class/graphics/fb0/modes
}

hdmi_check() {
  rm -f /run/drmMode /run/drmConn
  bash "${HDMI_CHECK}" </dev/null >hdmi-check.out 2>hdmi-check.err
}

test_hdmi_check_720p_mode() {
  setup
  fb_modes U:1280x720p-0
  hdmi_check
  assert_eq "$(cat /var/run/drmMode 2>/dev/null)" "5" "drmMode for a 1280 wide framebuffer"
}

test_hdmi_check_1080p_mode() {
  setup
  fb_modes U:1920x1080p-0
  hdmi_check
  assert_eq "$(cat /var/run/drmMode 2>/dev/null)" "2" "drmMode for a 1920 wide framebuffer"
}

test_hdmi_check_other_width() {
  setup
  fb_modes U:640x480p-0
  hdmi_check
  assert_eq "$(cat /var/run/drmMode 2>/dev/null)" "0" "drmMode for a 640 wide framebuffer"
}

test_hdmi_check_without_fb0() {
  local errors
  setup
  hdmi_check
  case "$(cat /var/run/drmMode 2>/dev/null)" in
    "" | 0) ;;
    *) fail "drmMode without fb0: $(cat /var/run/drmMode)" ;;
  esac
  errors=$(grep -E "${SHELL_ERRORS}" hdmi-check.err)
  [ -z "${errors}" ] || fail "shell errors without fb0:"$'\n'"${errors}"
}

run_quirk() {
  [ -f "$1" ] || return 0
  case "$(head -n 1 "$1")" in
    *bash*) timeout 10 bash "$1" ;;
    *) timeout 10 sh "$1" ;;
  esac </dev/null >>quirks.log 2>&1
}

device() {
  local name=$1 dir=${QUIRKS}/devices/$1 s
  rm -rf /sys/class/drm/* /sys/class/extcon
  echo "$2" >/sys/devices/virtual/graphics/fbcon/rotate
  printf '%s\0' "${name}" >/sys/firmware/devicetree/base/model
  shift 2
  drm "$@"
  for s in "${dir}/001-device_config" "${dir}/040-hdmi" "${dir}/081-dual_screen_mode" \
    "${QUIRKS}/autostart/080-dual_screen_mode"; do
    run_quirk "${s}"
  done
  cp "${SWAY}/autostart/111-sway-init" sway-init
  [ "$(. /etc/os-release; echo "${HW_DEVICE}")" != RK3588 ] || sed -i '/allow_tearing/d' sway-init
  bash sway-init </dev/null >sway-init.log 2>&1
  [ -s "${SWAY_CONFIG}" ] || fail "${name}: no sway config:"$'\n'"$(cat sway-init.log)"
}

validate() {
  mkdir -p rt
  chmod 700 rt
  [ -f "${SWAY_CONFIG%/*}/colorscheme" ] || cp "${SWAY}/config/colorscheme" "${SWAY_CONFIG%/*}/"
  XDG_RUNTIME_DIR=${PWD}/rt WLR_BACKENDS=headless WLR_RENDERER=pixman sway --validate -c "${SWAY_CONFIG}" \
    </dev/null >validate.log 2>&1 || fail "$1: sway rejects the config:"$'\n'"$(cat validate.log)"$'\n'"$(cat "${SWAY_CONFIG}")"
}

has() {
  grep -qxF -- "$1" "${SWAY_CONFIG}" || fail "${2:+$2: }[$1] not in the sway config:"$'\n'"$(cat "${SWAY_CONFIG}")"
}

sway_env() {
  (
    . "${SWAY_ENV}"
    eval echo "\"\${$1}\""
  )
}

empty_outputs() {
  grep -nE "output( *$| *[,'\"]| +(power|transform|disable|enable|pos|position|mode|bg|scale|allow_tearing|max_render_time)( |$))" \
    "${SWAY_CONFIG}"
}

test_sway_config_devices() {
  local name rotate cons main angle priority monitor extra line card
  local -a lines
  setup
  while IFS='|' read -r name rotate cons main angle priority monitor extra; do
    settings
    device "${name}" "${rotate}" ${cons}
    validate "${name}"
    [ -z "$(empty_outputs)" ] || fail "${name}: output commands without an output name:"$'\n'"$(empty_outputs)"
    card=${cons%%/*}
    [ "${card}" = "${cons}" ] && card=card0
    assert_eq "$(sway_env WLR_DRM_DEVICES)" "/dev/dri/${card}" "${name}: WLR_DRM_DEVICES"
    if [ "${main}" != "*" ]; then
      has "output ${main} transform ${angle}" "${name}"
      assert_eq "$(sway_env WLR_CON)" "${main}" "${name}: WLR_CON"
      assert_eq "$(sway_env WLR_CON_TRANSFORM)" "${angle}" "${name}: WLR_CON_TRANSFORM"
    fi
    [ "${priority}" = "*" ] || assert_eq "$(sway_env SDL_VIDEO_DISPLAY_PRIORITY)" "${priority}" "${name}: SDL_VIDEO_DISPLAY_PRIORITY"
    case "${monitor}" in
      yes) has "exec /usr/bin/output_monitor" "${name}" ;;
      no) grep -q output_monitor "${SWAY_CONFIG}" && fail "${name}: output_monitor started:"$'\n'"$(cat "${SWAY_CONFIG}")" ;;
    esac
    IFS=';' read -r -a lines <<<"${extra}"
    for line in "${lines[@]}"; do has "${line}" "${name}"; done
  done <<'EOF'
Retroid Pocket 5|3|DSI-1=connected DP-1=disconnected|DSI-1|270||yes|workspace 1 output DP-1 DSI-1
Retroid Pocket 5|3|DSI-1=connected DP-1=connected,SAMSUNG|DSI-1|270|*|yes|workspace 1 output DP-1 DSI-1
Retroid Pocket 5|3|DSI-1=connected DP-1=connected,Lontium|DSI-1|270|DP-1,DSI-1|*|output DP-1 transform 270;output DP-1 scale 1;output DP-1 position 0 0
Anbernic RG353P|0|DSI-1=connected HDMI-A-1=disconnected|DSI-1|0||yes|
Anbernic RG353P|1|DSI-1=connected HDMI-A-1=connected|HDMI-A-1|0|*|yes|output DSI-1 disable;output HDMI-A-1 mode 1920x1080@60Hz
Powkiddy x55|1|DSI-1=connected HDMI-A-1=disconnected|DSI-1|90||yes|
Game Console R36S|2|DSI-1=connected|DSI-1|180||no|
AYN Thor Lite|3|DSI-1=connected DSI-2=connected|DSI-1|270|DSI-1,DSI-2|no|output DSI-2 power off
AYN Thor|3|DSI-1=connected DSI-2=connected DP-1=disconnected|DSI-2|270|DSI-2,DSI-1|yes|output DSI-1 power off
AYANEO Pocket DS|1|DSI-1=connected DSI-2=connected DP-1=disconnected|*||DSI-1,DSI-2|yes|output DSI-2 power off
Anbernic RG DS|0|DSI-1=connected DSI-2=connected|DSI-2|0|DSI-2,DSI-1|no|exec_always swaymsg '[app_id="emulationstation"]' focus output DSI-2, output DSI-1 power off
Anbernic RG DS Plus|0|DSI-1=connected DSI-2=connected|DSI-2|0|DSI-2,DSI-1|no|exec_always swaymsg '[app_id="emulationstation"]' focus output DSI-2, output DSI-1 power off
Retroid Pocket Duo Lite|3|DSI-1=connected DP-1=disconnected|DSI-1|270|DSI-1,DP-1|no|exec swaymsg output DP-1 disable
Retroid Pocket Duo Lite|3|DSI-1=connected DP-1=connected|DSI-1|270|DSI-1,DP-1|no|exec swaymsg output DP-1 disable
MANGMI Air X MQ66B|1|DSI-1=connected DP-1=disconnected|DSI-1|90||yes|input type:touch map_to_output DSI-1
AYANEO Pocket S 2K|3|DSI-1=connected DP-1=disconnected|DSI-1|270||yes|
AYANEO AIR Plus|1|card1/eDP-1=connected card1/DP-1=disconnected card1/HDMI-A-1=disconnected|eDP-1|90||yes|
EOF
}

test_sway_config_desktop_mode() {
  setup
  settings desktop.enabled=1
  device "Retroid Pocket 5" 3 DSI-1=connected DP-1=disconnected
  validate "desktop mode"
  has "include colorscheme" "desktop mode"
  has "output DSI-1 transform 270" "desktop mode"
  assert_eq "$(setting desktop.enabled)" "0" "desktop.enabled after starting the desktop"
  assert_eq "$(actions)" "systemctl mask essway.service" "essway in desktop mode"
  : >actions
  echo masked >essway
  device "Retroid Pocket 5" 3 DSI-1=connected DP-1=disconnected
  validate "kiosk mode after the desktop"
  has "default_border none" "kiosk mode"
  assert_eq "$(actions)" "systemctl unmask essway.service" "essway back in kiosk mode"
}

test_sway_config_display_mode() {
  local rotate fb mode
  setup
  while read -r rotate fb mode; do
    settings system.display_mode=120
    echo "${fb/x/ }" >fb
    device "Retroid Pocket 5" "${rotate}" DSI-1=connected DP-1=disconnected
    validate "display mode with fbcon rotate ${rotate}"
    has "output DSI-1 mode ${mode}" "fbcon rotate ${rotate}"
  done <<'EOF'
0 1920x1080 1920x1080@120Hz
1 1080x1920 1080x1920@120Hz
3 1080x1920 1080x1920@120Hz
EOF
}

test_sway_config_display_mode_upside_down_panel() {
  setup
  settings system.display_mode=120
  echo 1920 1080 >fb
  device "Retroid Pocket 5" 2 DSI-1=connected DP-1=disconnected
  validate "display mode with fbcon rotate 2"
  has "output DSI-1 transform 180"
  has "output DSI-1 mode 1920x1080@120Hz" "fbcon rotate 2"
}

test_dual_screen_mode_ignores_external_displays() {
  local want cons
  setup
  while read -r want cons; do
    settings
    rm -rf /sys/class/drm/*
    drm ${cons}
    run_quirk "${QUIRKS}/autostart/080-dual_screen_mode"
    assert_eq "$(. /storage/.config/profile.d/080-dual_screen_mode && echo "${DEVICE_HAS_DUAL_SCREEN}")" "${want}" "${cons}"
  done <<'EOF'
false DSI-1=connected DP-1=connected,SAMSUNG
false DSI-1=connected HDMI-A-1=connected
true DSI-1=connected DSI-2=connected DP-1=connected,SAMSUNG
true DSI-1=connected DP-1=connected,Lontium
EOF
}

test_sway_dual_screen_with_external_at_boot() {
  setup
  settings
  device "AYN Thor" 3 DSI-1=connected DSI-2=connected DP-1=connected,SAMSUNG
  validate "AYN Thor with a DP display at boot"
  [ -z "$(empty_outputs)" ] || fail "output commands without an output name:"$'\n'"$(empty_outputs)"
  has "output DSI-1 power off" "bottom screen"
  assert_eq "$(sway_env SDL_VIDEO_DISPLAY_PRIORITY)" "DSI-2,DSI-1" "SDL_VIDEO_DISPLAY_PRIORITY"
}

test_sway_dual_screen_addon_keeps_panel_on() {
  setup
  settings
  device "Retroid Pocket 5" 3 DSI-1=connected DP-1=connected,Lontium
  has "output DP-1 transform 270" "dual screen add-on"
  grep -qxF "exec /usr/bin/output_monitor" "${SWAY_CONFIG}" || return 0
  audio 48 "0:off 2:HiFi 5:HDMI"
  outputs DSI-1=yes DP-1=yes
  start_monitor
  ! logged "wlr-randr --output DSI-1 --off" || fail "output_monitor turns the panel off with the dual screen add-on:"$'\n'"$(actions)"
}
