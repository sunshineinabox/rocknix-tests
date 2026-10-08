# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PACKAGES=${REPO}/projects/ROCKNIX/packages
SCRIPTS=${PACKAGES}/rocknix/sources/scripts
FUNCTIONS=${PACKAGES}/rocknix/profile.d/001-functions

outputs() {
  stub /usr/bin/swaymsg <<'EOF'
#!/bin/sh
if [ "$1" = "-t" ]; then
  cat <<'JSON'
[
  {"name": "DSI-1", "active": true, "transform": "270", "current_mode": {"width": 1080, "height": 1920, "refresh": 60000}},
  {"name": "DSI-2", "active": true, "transform": "normal", "current_mode": {"width": 1080, "height": 1240, "refresh": 60000}},
  {"name": "DSI-4", "active": true, "transform": "flipped-90", "current_mode": {"width": 1080, "height": 1920, "refresh": 60000}},
  {"name": "eDP-1", "active": true, "transform": "180", "current_mode": {"width": 1920, "height": 1080, "refresh": 60000}},
  {"name": "HDMI-A-1", "active": true, "transform": "normal", "current_mode": {"width": 1920, "height": 1080, "refresh": 60000}},
  {"name": "DP-1", "active": false, "transform": "normal", "current_mode": null}
]
JSON
else
  echo "$*" >>/tmp/swaymsg.log
fi
EOF
}

scanout_cleanup() {
  unstub /usr/bin/swaymsg
  rm -rf /run/rocknix /tmp/swaymsg.log /storage/.config
}

test_plane_rotation_settings() {
  local value disabled rc max
  trap 'rm -rf /storage/.config' EXIT
  . "${FUNCTIONS}"
  while read -r value disabled rc max; do
    DEVICE_PLANE_ROTATION=${value#-}
    rm -rf /storage/.config
    if [ "${disabled}" = yes ]; then
      mkdir -p /storage/.config
      : >/storage/.config/rotator.disabled
    fi
    plane_rotation
    assert_eq "$?" "${rc}" "plane_rotation with [${DEVICE_PLANE_ROTATION}], rotator.disabled ${disabled}"
    assert_eq "$(plane_rotation_max_height)" "${max}" "plane_rotation_max_height with [${DEVICE_PLANE_ROTATION}]"
  done <<'EOF'
- no 1
false no 1
true no 0
1088 no 0 1088
1200 no 0 1200
true yes 1
1200 yes 1 1200
EOF
}

test_plane_rotates() {
  local value transform lines rc
  trap 'rm -rf /storage/.config' EXIT
  rm -rf /storage/.config
  . "${FUNCTIONS}"
  while read -r value transform lines rc; do
    DEVICE_PLANE_ROTATION=${value}
    plane_rotates "${transform}" "${lines#-}"
    assert_eq "$?" "${rc}" "plane_rotates ${transform} ${lines} with DEVICE_PLANE_ROTATION=${value}"
  done <<'EOF'
true 90 1920 0
true 270 2400 0
true 180 1080 0
1088 90 1080 0
1088 270 1088 0
1088 270 1200 1
1088 90 - 1
1088 180 2400 0
1088 0 2400 0
false 0 1080 1
false 180 1080 1
false 270 1080 1
EOF
}

test_prerotate_env() {
  local pre plane transform lines want
  trap 'rm -rf /storage/.config' EXIT
  rm -rf /storage/.config
  . "${FUNCTIONS}"
  while read -r pre plane transform lines want; do
    DEVICE_PRE_ROTATION=${pre} DEVICE_PLANE_ROTATION=${plane}
    export vk_wsi_wayland_prerotate=stale egl_wayland_prerotate=stale
    prerotate_env "${transform}" "${lines#-}" || fail "prerotate_env returned non-zero"
    assert_eq "${vk_wsi_wayland_prerotate:-none} ${egl_wayland_prerotate:-none}" "${want} ${want}" \
      "pre=${pre} plane=${plane} transform=${transform} lines=${lines}"
    [ "${want}" = none ] || assert_eq "$(sh -c 'echo ${vk_wsi_wayland_prerotate}')" "${want}" "exported"
  done <<'EOF'
false false 90 1080 none
true false 90 1080 270
true false 270 1080 90
true false 180 1080 180
true false 0 1080 none
true false normal 1080 none
true true 90 1080 none
true true 180 1080 none
true 1088 270 1080 none
true 1088 270 1200 90
true 1088 90 - 270
true 1088 180 2400 none
EOF
}

test_scanout_output_size() {
  local output orient want
  trap 'scanout_cleanup' EXIT
  outputs
  . "${FUNCTIONS}"
  while read -r output orient want; do
    assert_eq "$(scanout_output_size "${output}" "${orient#-}")" "${want}" "${output} ${orient}"
  done <<'EOF'
DSI-1 - 1920 1080
DSI-1 landscape 1920 1080
DSI-4 - 1920 1080
eDP-1 - 1920 1080
HDMI-A-1 - 1920 1080
DSI-2 - 1080 1240
DSI-2 landscape 1240 1080
DP-1 -
VIRTUAL-9 -
EOF
}

test_scanout_internal_scale() {
  local render max cur lines lo hi step want
  trap 'scanout_cleanup' EXIT
  outputs
  . "${FUNCTIONS}"
  SCANOUT_OUTPUT=DSI-1
  while read -r render max cur lines lo hi step want; do
    SCANOUT_RENDER=${render#-} SCANOUT_MAX_RENDER=${max}
    assert_eq "$(scanout_internal_scale "${cur}" "${lines}" "${lo}" "${hi}" "${step}")" "${want}" \
      "render ${render} max ${max}% cur ${cur} lines ${lines} range ${lo}-${hi} step ${step}"
  done <<'EOF'
internal 400 3 240 1 16 1 3
off 400 3 240 1 16 1 3
- 400 3 240 1 16 1 3
0x 400 5 240 1 16 1 5
4x 400 2 240 1 16 1 4
2x 400 1 240 3 16 1 3
8x 400 1 240 1 4 1 4
16x 400 1 240 1 16 1 16
16x 200 1 240 1 16 1 9
1.5x 400 1 480 0.5 6 0.25 1.5
1.6x 400 1 480 0.5 6 0.25 1.5
8x 133 1 480 0.5 6 0.5 2.5
4x 100 1 448 1 8 1 2
8x 100 1 1080 1 8 1 1
4x 100 1 2000 1 8 1 1
EOF
}

test_scanout_render_size() {
  local output plane render max args line pre hint calls
  trap 'scanout_cleanup' EXIT
  outputs
  . "${FUNCTIONS}"
  export SCANOUT_OWNER=4242 SCANOUT_OUTPUT2=DSI-2 DEVICE_PRE_ROTATION=true
  while IFS='|' read -r output plane render max args line pre hint calls; do
    read -r SCANOUT_OUTPUT SCANOUT_TRANSFORM <<<"${output}"
    DEVICE_PLANE_ROTATION=${plane} SCANOUT_RENDER=${render} SCANOUT_MAX_RENDER=${max}
    unset vk_wsi_wayland_prerotate egl_wayland_prerotate
    rm -rf /run/rocknix /tmp/swaymsg.log
    scanout_render_size ${args} >out
    assert_eq "$(cat out)" "${line}" "${output} ${render} ${args}"
    assert_eq "${vk_wsi_wayland_prerotate:-none} ${egl_wayland_prerotate:-none}" "${pre} ${pre}" \
      "${output} ${render} ${args}: pre-rotation"
    assert_eq "$(cat /run/rocknix/fullscreen-scale-hint 2>/dev/null)" "${hint}" "${output} ${render} ${args}: hint"
    assert_eq "$(cat /tmp/swaymsg.log 2>/dev/null)" "${calls}" "${output} ${render} ${args}: swaymsg"
  done <<'EOF'
DSI-1 270|true|internal|133|240 1 4:3|Scan-out: 240 lines x1 4:3 on DSI-1: 240 of 1080 lines, pre-rotation none|none|0.222222 4242 DSI-1|output DSI-1 scale 4.500000
DSI-1 270|true|3x|133|240 3 4:3|Scan-out: 240 lines x3 4:3 on DSI-1: 720 of 1080 lines, pre-rotation none|none|0.666667 4242 DSI-1|output DSI-1 scale 1.500000
DSI-1 270|true|6x|133|480 6 4:3|Scan-out: 480 lines x6 4:3 on DSI-1: 960 of 1080 lines, pre-rotation none|none|0.888889 4242 DSI-1|output DSI-1 scale 1.125000
DSI-1 270|true|2x|133|480 2 16:9|Scan-out: 480 lines x2 16:9 on DSI-1: 960 of 1080 lines, pre-rotation none|none|0.888889 4242 DSI-1|output DSI-1 scale 1.125000
DSI-1 270|true|internal|133|1080 1 16:9|Scan-out: 1080 lines x1 16:9 on DSI-1: 1080 of 1080 lines, pre-rotation none|none||
DSI-1 270|false|internal|133|240 1 4:3|Scan-out: 240 lines x1 4:3 on DSI-1: 240 of 1080 lines, pre-rotation 90|90|0.222222 4242 DSI-1|output DSI-1 scale 4.500000
DSI-1 270|1088|2x|133|544 2 960:544|Scan-out: 544 lines x2 960:544 on DSI-1: 1088 of 1080 lines, pre-rotation none|none|1.007407 4242 DSI-1|
DSI-1 270|1088|3x|133|448 3 4:3|Scan-out: 448 lines x3 4:3 on DSI-1: 1344 of 1080 lines, pre-rotation 90|90|1.244444 4242 DSI-1|
DSI-1 270|true|75|133|240 1 4:3||none||
DSI-1 270|true|off|133|240 1 4:3||none||
HDMI-A-1 normal|false|internal|400|224 1 4:3|Scan-out: 224 lines x1 4:3 on HDMI-A-1: 224 of 1080 lines, pre-rotation none|none|0.207612 4242 HDMI-A-1|output HDMI-A-1 scale 4.816667
DSI-1 270|true|50|133|192 1 256:192 second|Scan-out: 192 lines x1 256:192 on DSI-2: 540 of 1080 lines, pre-rotation none|none|0.500000 4242 DSI-2|output DSI-2 scale 2.000000
DSI-1 270|true|internal|133|192 2 256:192 second|Scan-out: 192 lines x2 256:192 on DSI-2: 446 of 1080 lines, pre-rotation none|none|0.413793 4242 DSI-2|output DSI-2 scale 2.416667
EOF
}

test_scanout_render_size_needs_an_owner() {
  trap 'scanout_cleanup' EXIT
  outputs
  . "${FUNCTIONS}"
  unset SCANOUT_OWNER
  SCANOUT_OUTPUT=DSI-1 SCANOUT_RENDER=internal
  assert_eq "$(scanout_render_size 240 1 4:3)" "" "no owner"
  [ -e /run/rocknix ] && fail "wrote $(ls /run/rocknix) without an owner"
  return 0
}

test_scanout_scale_restored_and_reset() {
  local f
  trap 'scanout_cleanup' EXIT
  outputs
  . "${FUNCTIONS}"
  rm -rf /run/rocknix /tmp/swaymsg.log
  export SCANOUT_OWNER=4242 SCANOUT_OUTPUT=DSI-1 SCANOUT_TRANSFORM=270 SCANOUT_RENDER=internal SCANOUT_MAX_RENDER=133
  DEVICE_PLANE_ROTATION=true DEVICE_PRE_ROTATION=true
  scanout_claim
  scanout_render_size 240 1 4:3 >/dev/null
  scanout_render_size 1080 1 16:9 >/dev/null
  assert_eq "$(tr '\n' ';' </tmp/swaymsg.log)" "output DSI-1 scale 4.500000;output DSI-1 scale 1;" "scale restored at native height"
  assert_eq "$(cat /run/rocknix/fullscreen-scale-hint)" "" "hint dropped at native height"
  assert_eq "$(cat /run/rocknix/scanout-owner)" "4242" "owner"
  mkdir dpu
  for f in dpu_de dpu_de_sharpen1 dpu_de_sharpen2 dpu_de_unscaled dpu_nearest dpu_de_dir dpu_de_dir_weight; do
    echo 7 >dpu/${f}
  done
  DEVICE_SCANOUT_SHARPNESS=${PWD}/dpu
  rm -f /tmp/swaymsg.log
  scanout_reset
  assert_eq "$(cat /tmp/swaymsg.log)" "output DSI-1 scale 1" "reset scale"
  assert_eq "$(cd dpu && for f in dpu_de dpu_de_sharpen1 dpu_de_sharpen2 dpu_de_unscaled dpu_nearest dpu_de_dir dpu_de_dir_weight; do
    cat ${f}; done | tr '\n' ' ')" "Y 12 12 N N N 32 " "driver defaults"
  assert_eq "$(ls -A /run/rocknix)" "" "state files removed"
}

test_scanout_reset_stale() {
  local runemu
  trap 'scanout_cleanup; kill ${runemu} 2>/dev/null' EXIT
  outputs
  . "${FUNCTIONS}"
  mkfifo hold
  bash -c 'read -r _ <"$1"' runemu.sh hold &
  runemu=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep -qa runemu.sh /proc/${runemu}/cmdline 2>/dev/null && break
    sleep 0.1
  done
  rm -rf /run/rocknix /tmp/swaymsg.log
  scanout_reset_stale
  [ -e /tmp/swaymsg.log ] && fail "reset without an owner file"
  mkdir -p /run/rocknix
  echo DSI-1 >/run/rocknix/scanout-scaled-outputs
  echo "${runemu}" >/run/rocknix/scanout-owner
  scanout_reset_stale
  assert_eq "$(cat /run/rocknix/scanout-owner)" "${runemu}" "owner kept while runemu runs"
  echo $$ >/run/rocknix/scanout-owner
  scanout_reset_stale
  [ -e /run/rocknix/scanout-owner ] && fail "owner kept for a process that is not runemu"
  assert_eq "$(cat /tmp/swaymsg.log)" "output DSI-1 scale 1" "scale reset"
  echo 4194303 >/run/rocknix/scanout-owner
  scanout_reset_stale
  [ -e /run/rocknix/scanout-owner ] && fail "owner kept for a process that exited"
  return 0
}

test_timeinfo() {
  local zones zone
  trap 'rm -f /etc/localtime; mv /etc/localtime.orig /etc/localtime' EXIT
  mv /etc/localtime /etc/localtime.orig
  for zone in Europe/Berlin America/Argentina/Buenos_Aires; do
    ln -sfn "/usr/share/zoneinfo/${zone}" /etc/localtime
    assert_eq "$(bash "${SCRIPTS}/timeinfo" current_timezone)" "${zone}" "current_timezone"
  done
  zones=$(bash "${SCRIPTS}/timeinfo" timezones)
  assert_contains "${zones}" $'\nEurope/Berlin,\n' "timezones"
  assert_contains "${zones}" $'\nAmerica/New_York,\n' "timezones"
  assert_eq "$(echo "${zones}" | grep -cvE '^[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+,$')" "0" "every zone is Area/Location,"
  assert_eq "$(echo "${zones}" | sort -u)" "${zones}" "sorted and unique"
  assert_eq "$(bash "${SCRIPTS}/timeinfo" bogus)" "" "unknown command"
}

test_rocknix_info_sections() {
  local out err
  trap 'rm -f /tmp/battery.percent' EXIT
  echo 77 >/tmp/battery.percent
  out=$(bash "${SCRIPTS}/rocknix-info" 2>err)
  err=$(grep -E 'syntax error|command not found|integer expression|bad substitution|unbound variable' err)
  [ -z "${err}" ] || fail "${err}"
  . /etc/os-release
  assert_eq "$(echo "${out}" | grep -E '^[A-Z ]+(INFORMATION|SPACE):$' | tr '\n' ';')" \
    "SYSTEM INFORMATION:;NETWORK INFORMATION:;DISK SPACE:;BATTERY INFORMATION:;CPU INFORMATION:;GPU INFORMATION:;RAM INFORMATION:;" \
    "sections"
  assert_contains "${out}" $'\n'"OPERATING SYSTEM: ${OS_NAME}"$'\n' "os name"
  assert_contains "${out}" $'\n'"VERSION: ${OS_VERSION} (${OS_BUILD})"$'\n' "version"
  assert_contains "${out}" $'\n'"BUILD ID: ${BUILD_ID:0:7} (${BUILD_BRANCH})"$'\n' "build id"
  assert_contains "${out}" $'\nBATTERY REMAINING: 77%\n' "battery"
  assert_contains "${out}" $'\n'"RAM CAPACITY: $(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1000)) MB" "ram"
  assert_contains "${out}" "($(grep -c '^processor' /proc/cpuinfo) Cores)" "cores"
  echo "$(bash "${SCRIPTS}/rocknix-info" --short 2>/dev/null)" | grep -qxE 'Battery: 77% - [0-2][0-9]:[0-5][0-9]' ||
    fail "--short: $(bash "${SCRIPTS}/rocknix-info" --short 2>/dev/null)"
}

test_rocknix_info_exit_status() {
  local rc
  trap 'rm -f /tmp/battery.percent' EXIT
  echo 77 >/tmp/battery.percent
  bash "${SCRIPTS}/rocknix-info" >/dev/null 2>&1
  rc=$?
  assert_eq "${rc}" "0" "rocknix-info exit status"
}

games_freeze() {
  rm -f /tmp/systemctl.log
  sh "${SCRIPTS}/rocknix-games-freeze" "$@" </dev/null >out 2>err
}

test_games_freeze() {
  local rc
  trap 'unstub /usr/bin/systemctl; rm -f /tmp/systemctl.log /tmp/games.active /tmp/games.fail' EXIT
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/systemctl.log
case "$*" in
  "-q is-active games.slice") [ -e /tmp/games.active ] || exit 3 ;;
  *" games.slice") [ -e /tmp/games.fail ] && exit 1 ;;
esac
exit 0
EOF
  rm -f /tmp/games.active /tmp/games.fail
  games_freeze freeze
  assert_eq "$? $(tr '\n' ';' </tmp/systemctl.log)" "0 -q is-active games.slice;" "freeze without running games"
  touch /tmp/games.active
  games_freeze freeze
  assert_eq "$? $(tr '\n' ';' </tmp/systemctl.log)" "0 -q is-active games.slice;freeze games.slice;" "freeze"
  games_freeze thaw
  assert_eq "$? $(tr '\n' ';' </tmp/systemctl.log)" "0 -q is-active games.slice;thaw games.slice;" "thaw"
  touch /tmp/games.fail
  games_freeze freeze
  assert_eq "$?" "1" "failed freeze is reported"
  games_freeze stop
  rc=$?
  assert_eq "${rc} $(cat /tmp/systemctl.log 2>/dev/null)" "1 " "unknown action"
  assert_contains "$(cat err)" "usage:" "usage on stderr"
  games_freeze
  assert_eq "$?" "1" "no action"
}
