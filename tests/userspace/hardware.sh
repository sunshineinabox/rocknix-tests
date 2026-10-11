# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)
# privileged

PACKAGES=${REPO}/projects/ROCKNIX/packages
SCRIPTS=${PACKAGES}/rocknix/sources/scripts
PROFILED=${PACKAGES}/rocknix/profile.d
QUIRKS=${PACKAGES}/hardware/quirks
SYSUTILS=${PACKAGES}/sysutils/system-utils/sources/scripts
CFG=/storage/.config/system/configs/system.cfg
CPU=/sys/devices/system/cpu

settings() {
  rm -rf /storage/.config
  mkdir -p "${CFG%/*}"
  printf '%s\n' "$@" >"${CFG}"
}

setting() {
  sed -n "s/^$1=//p" "${CFG}"
}

fake() {
  mount -t tmpfs fake "$1" || fail "cannot mount a tmpfs on $1"
}

backlight() {
  mkdir -p "/sys/class/backlight/$1"
  echo "$2" >"/sys/class/backlight/$1/max_brightness"
  echo 0 >"/sys/class/backlight/$1/brightness"
}

cpu_tree() {
  local n
  fake ${CPU}
  echo 0-7 >${CPU}/online
  for n in 0 1 2 3 4 5 6 7; do
    mkdir -p ${CPU}/cpu${n}
    echo 1 >${CPU}/cpu${n}/online
  done
  for n in 0 4 7; do
    mkdir -p ${CPU}/cpufreq/policy${n}
    echo schedutil >${CPU}/cpufreq/policy${n}/scaling_governor
  done
  echo 0 >${CPU}/cpufreq/boost
}

devfreq() {
  mkdir -p "$1"
  echo "$2" >"$1/available_governors"
  : >"$1/governor"
}

meminfo() {
  printf 'MemTotal: %s kB\nMemFree: %s kB\nMemAvailable: %s kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' \
    "$1" $(($1 / 2)) $(($1 / 2)) >"${PWD}/meminfo"
}

swap_conf() {
  rm -rf /storage/.config
  mkdir -p /storage/.config
  printf '%s\n' "$@" >/storage/.config/swap.conf
}

hw_device() {
  sed "s/^HW_DEVICE=.*/HW_DEVICE=\"$1\"/" release | stub /etc/os-release
}

test_volume_steps_clamps_and_saves() {
  local start arg want
  trap 'unstub /usr/bin/pactl; rm -rf /storage/.config /tmp/pactl.log' EXIT
  stub /usr/bin/pactl <<'EOF'
#!/bin/sh
echo "$*" >/tmp/pactl.log
EOF
  while read -r start arg want; do
    settings "audio.volume=${start}"
    rm -f /tmp/pactl.log
    sh "${SCRIPTS}/volume" "${arg}" </dev/null >/dev/null 2>&1
    assert_eq "$(cat /tmp/pactl.log 2>/dev/null)" "-- set-sink-volume @DEFAULT_SINK@ ${want}%" "volume ${arg} from ${start}"
    assert_eq "$(setting audio.volume)" "${want}" "saved volume after volume ${arg} from ${start}"
  done <<'EOF'
60 up 65
60 + 65
60 down 55
60 - 55
98 up 100
3 down 0
60 restore 60
60 30 30
60 150 100
60 -20 0
EOF
}

test_volume_restore_without_setting() {
  trap 'unstub /usr/bin/pactl; rm -rf /storage/.config /tmp/pactl.log' EXIT
  stub /usr/bin/pactl <<'EOF'
#!/bin/sh
echo "$*" >/tmp/pactl.log
EOF
  settings
  sh "${SCRIPTS}/volume" restore </dev/null >/dev/null 2>&1
  assert_eq "$(cat /tmp/pactl.log 2>/dev/null)" "-- set-sink-volume @DEFAULT_SINK@ 50%" "default volume"
  assert_eq "$(setting audio.volume)" "50" "saved default volume"
}

test_brightness_set_scales_to_max_brightness() {
  local max pct raw saved
  trap 'umount /sys/class; rm -rf /storage/.config' EXIT
  fake /sys/class
  while read -r max pct raw saved; do
    rm -rf /sys/class/backlight
    backlight backlight "${max}"
    settings display.brightness=50
    bash "${SCRIPTS}/brightness" set "${pct}" </dev/null >/dev/null 2>&1
    assert_eq "$(cat /sys/class/backlight/backlight/brightness)" "${raw}" "set ${pct}% with max_brightness ${max}"
    assert_eq "$(setting display.brightness)" "${saved}" "saved brightness after set ${pct}%"
  done <<'EOF'
255 50 127 50
255 100 255 100
255 0 12 5
255 4 12 5
204 75 153 75
429 20 85 20
4095 33 1351 33
2539 1 126 5
255 101 0 50
EOF
}

test_brightness_steps() {
  local start action raw saved
  trap 'umount /sys/class; rm -rf /storage/.config' EXIT
  fake /sys/class
  while read -r start action raw saved; do
    rm -rf /sys/class/backlight
    backlight panel 255
    settings "display.brightness=${start}"
    bash "${SCRIPTS}/brightness" "${action}" </dev/null >/dev/null 2>&1
    assert_eq "$(cat /sys/class/backlight/panel/brightness)" "${raw}" "${action} from ${start}%"
    assert_eq "$(setting display.brightness)" "${saved}" "saved brightness after ${action} from ${start}%"
  done <<'EOF'
50 up 140 55
3 up 20 8
98 up 255 100
100 up 255 100
50 down 114 45
7 down 12 5
5 down 12 5
EOF
}

test_brightness_per_screen() {
  trap 'umount /sys/class; rm -rf /storage/.config' EXIT
  fake /sys/class
  backlight dsi0 255
  backlight dsi1 1023
  settings display.brightness=50 display.brightness2=20
  bash "${SCRIPTS}/brightness" set 2 60 </dev/null >/dev/null 2>&1
  assert_eq "$(cat /sys/class/backlight/dsi0/brightness) $(cat /sys/class/backlight/dsi1/brightness)" "0 613" "set 2 60"
  assert_eq "$(setting display.brightness) $(setting display.brightness2)" "50 60" "settings after set 2 60"
  bash "${SCRIPTS}/brightness" up </dev/null >/dev/null 2>&1
  assert_eq "$(cat /sys/class/backlight/dsi0/brightness) $(cat /sys/class/backlight/dsi1/brightness)" "140 664" "up on all"
  assert_eq "$(setting display.brightness) $(setting display.brightness2)" "55 65" "settings after up"
  assert_eq "$(bash "${SCRIPTS}/brightness" 2 </dev/null 2>/dev/null)" "664" "read screen 2"
  assert_eq "$(bash "${SCRIPTS}/brightness" </dev/null 2>/dev/null)" "140" "read screen 1"
  bash "${SCRIPTS}/brightness" down 3 </dev/null >/dev/null 2>&1 && fail "screen 3 accepted"
  return 0
}

test_cpu_governor_presets() {
  local preset cpu dmc n
  trap 'umount '"${CPU}"'; rm -rf /storage/.config' EXIT
  rm -rf /storage/.config
  cpu_tree
  devfreq dmc "performance powersave ondemand"
  . "${PROFILED}/001-functions"
  . "${PROFILED}/099-freqfunctions"
  DMC_FREQ=${PWD}/dmc
  while read -r preset cpu dmc; do
    ${preset} </dev/null
    for n in 0 4 7; do
      assert_eq "$(cat ${CPU}/cpufreq/policy${n}/scaling_governor)" "${cpu}" "${preset}: policy${n}"
    done
    assert_eq "$(cat dmc/governor)" "${dmc}" "${preset}: dmc"
    assert_eq "$(cat ${CPU}/cpufreq/boost)" "0" "${preset}: boost untouched"
  done <<'EOF'
performance performance performance
ondemand ondemand ondemand
schedutil schedutil ondemand
powersave powersave powersave
EOF
}

test_devfreq_governor_fallback() {
  local call node want
  trap 'umount '"${CPU}"'; rm -rf /storage/.config' EXIT
  rm -rf /storage/.config
  cpu_tree
  devfreq gpu "simple_ondemand userspace powersave performance"
  devfreq dmc "dmc_ondemand userspace powersave performance simple_ondemand"
  . "${PROFILED}/001-functions"
  . "${PROFILED}/099-freqfunctions"
  GPU_FREQ=${PWD}/gpu
  DMC_FREQ=${PWD}/dmc
  echo() {
    local pid=${BASHPID} target
    target=$(readlink "/proc/${pid}/fd/1")
    case "${target}" in
      */governor)
        case " $(<"${target%/governor}/available_governors") " in
          *" $1 "*) ;;
          *) return 1 ;;
        esac
        ;;
    esac
    builtin echo "$@"
  }
  while IFS='|' read -r call node want; do
    ${call} </dev/null
    assert_eq "$(cat ${node}/governor)" "${want}" "${call}"
  done <<'EOF'
gpu_performance_level auto|gpu|simple_ondemand
gpu_performance_level performance|gpu|performance
gpu_performance_level default|gpu|simple_ondemand
gpu_performance_level powersave|gpu|powersave
ondemand|dmc|dmc_ondemand
performance|dmc|performance
schedutil|dmc|dmc_ondemand
powersave|dmc|powersave
EOF
  unset -f echo
  assert_eq "$(get_available_gpu_governors | tr '\n' ' ')" "default simple_ondemand userspace powersave performance " \
    "available gpu governors"
}

test_online_threads() {
  local threads want n got
  trap 'umount '"${CPU}"'; rm -rf /storage/.config' EXIT
  rm -rf /storage/.config
  cpu_tree
  . "${PROFILED}/001-functions"
  . "${PROFILED}/099-freqfunctions"
  while read -r threads want; do
    for n in 1 2 3; do echo 1 >${CPU}/cpu${n}/online; done
    for n in 4 5 6 7; do echo 0 >${CPU}/cpu${n}/online; done
    onlinethreads ${threads} </dev/null
    got=$(for n in 0 1 2 3 4 5 6 7; do cat ${CPU}/cpu${n}/online; done | tr -d '\n')
    assert_eq "${got}" "${want}" "onlinethreads ${threads}"
  done <<'EOF'
all 11111111
default 11110000
8 11111111
6 11111100
4 11110000
2 11000000
1 10000000
0 10000000
EOF
}

test_gpu_profiling_toggles_panfrost() {
  local device state want
  trap 'umount /sys/bus/platform' EXIT
  fake /sys/bus/platform
  mkdir -p /sys/bus/platform/drivers/panfrost/ff400000.gpu
  echo 0 >/sys/bus/platform/drivers/panfrost/ff400000.gpu/profiling
  . "${PROFILED}/101-gpu-functions"
  while read -r device state want; do
    HW_DEVICE=${device} gpu_profiling ${state}
    assert_eq "$(cat /sys/bus/platform/drivers/panfrost/ff400000.gpu/profiling)" "${want}" "${device} ${state}"
  done <<'EOF'
RK3326 on 1
RK3326 off 0
S922X on 1
RK3566 off 1
SM8250 off 1
S922X off 0
EOF
}

test_battery_percent() {
  trap 'umount /sys/class; rm -f /tmp/battery.percent' EXIT
  rm -f /tmp/battery.percent
  fake /sys/class
  . "${PROFILED}/001-functions"
  mkdir -p /sys/class/power_supply/usb /sys/class/power_supply/battery
  printf 'POWER_SUPPLY_NAME=usb\nPOWER_SUPPLY_ONLINE=1\n' >/sys/class/power_supply/usb/uevent
  assert_eq "$(battery_percent)" "" "no battery"
  printf 'POWER_SUPPLY_NAME=battery\nPOWER_SUPPLY_STATUS=Discharging\nPOWER_SUPPLY_CAPACITY=55\nPOWER_SUPPLY_CAPACITY_LEVEL=Normal\n' \
    >/sys/class/power_supply/battery/uevent
  assert_eq "$(battery_percent)" "55" "battery"
  mv /sys/class/power_supply/battery /sys/class/power_supply/BAT0
  sed -i 's/=55$/=87/' /sys/class/power_supply/BAT0/uevent
  assert_eq "$(battery_percent)" "87" "BAT0"
  echo 42 >/tmp/battery.percent
  assert_eq "$(battery_percent)" "42" "batteryplus value"
}

fb_setup() {
  fake /sys/devices/virtual
  mkdir -p /sys/devices/virtual/graphics/fbcon
  stub /usr/sbin/fbset <<'EOF'
#!/bin/sh
printf '\nmode "1080x1920"\n    geometry 1080 1920 1080 1920 32\n    timings 0 0 0 0 0 0 0\n    rgba 8/16,8/8,8/0,0/0\nendmode\n\n'
EOF
  . "${PROFILED}/001-functions"
}

test_fb_size_follows_console_rotation() {
  local rotate want
  trap 'umount /sys/devices/virtual; unstub /usr/sbin/fbset' EXIT
  fb_setup
  while read -r rotate want; do
    echo "${rotate}" >/sys/devices/virtual/graphics/fbcon/rotate
    assert_eq "$(fbwidth) $(fbheight)" "${want}" "fbcon rotate ${rotate}"
  done <<'EOF'
0 1080 1920
1 1920 1080
3 1920 1080
EOF
}

test_fb_size_upside_down_console() {
  trap 'umount /sys/devices/virtual; unstub /usr/sbin/fbset' EXIT
  fb_setup
  echo 2 >/sys/devices/virtual/graphics/fbcon/rotate
  assert_eq "$(fbwidth) $(fbheight)" "1080 1920" "fbcon rotate 2 keeps the panel width and height"
}

test_suspendmode_writes_sleep_conf() {
  local mode want
  trap 'unstub /usr/bin/systemctl; rm -rf /storage/.config /tmp/systemctl.log' EXIT
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/systemctl.log
EOF
  while read -r mode want; do
    settings
    mkdir -p /storage/.config/sleep.conf.d
    rm -f /tmp/systemctl.log
    sh "${SCRIPTS}/suspendmode" "${mode}" </dev/null >/dev/null 2>&1
    assert_eq "$(tr '\n' ';' </storage/.config/sleep.conf.d/sleep.conf)" "${want}" "sleep.conf for ${mode}"
    assert_eq "$(setting system.suspendmode)" "${mode}" "saved mode ${mode}"
    assert_eq "$(cat /tmp/systemctl.log 2>/dev/null)" "restart systemd-logind" "logind restart for ${mode}"
  done <<'EOF'
mem [Sleep];AllowSuspend=yes;SuspendState=mem standby freeze;
freeze [Sleep];AllowSuspend=yes;SuspendState=freeze standby mem;
standby [Sleep];AllowSuspend=yes;SuspendState=standby mem freeze;
off [Sleep];AllowSuspend=no;
EOF
}

test_suspendmode_same_mode_is_noop() {
  trap 'unstub /usr/bin/systemctl; rm -rf /storage/.config /tmp/systemctl.log' EXIT
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/systemctl.log
EOF
  rm -f /tmp/systemctl.log
  settings system.suspendmode=freeze
  mkdir -p /storage/.config/sleep.conf.d
  echo untouched >/storage/.config/sleep.conf.d/sleep.conf
  sh "${SCRIPTS}/suspendmode" freeze </dev/null >/dev/null 2>&1
  assert_eq "$(cat /storage/.config/sleep.conf.d/sleep.conf)" "untouched" "sleep.conf"
  [ -e /tmp/systemctl.log ] && fail "systemctl called: $(cat /tmp/systemctl.log)"
  return 0
}

test_suspendmode_default_runs_platform_quirk() {
  local quirk
  quirk=/usr/lib/autostart/quirks/platforms/$(. /etc/os-release; echo "${HW_DEVICE}")/030-suspend_mode
  trap 'unstub /usr/bin/systemctl "'"${quirk}"'"; rm -rf /storage/.config /tmp/systemctl.log' EXIT
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/systemctl.log
EOF
  stub "${quirk}" <<'EOF'
#!/bin/sh
echo quirk >>/tmp/systemctl.log
EOF
  rm -f /tmp/systemctl.log
  settings system.suspendmode=freeze
  mkdir -p /storage/.config/sleep.conf.d
  QUIRK_DEVICE="" sh "${SCRIPTS}/suspendmode" default </dev/null >/dev/null 2>&1
  assert_eq "$(tr '\n' ';' </storage/.config/sleep.conf.d/sleep.conf)" "[Sleep];" "sleep.conf"
  assert_eq "$(setting system.suspendmode)" "" "suspend mode setting removed"
  assert_eq "$(tr '\n' ';' </tmp/systemctl.log)" "quirk;restart systemd-logind;" "quirk then logind restart"
}

test_led_scripts_dispatch_to_quirks() {
  local script dev="/usr/lib/autostart/quirks/devices/Test Handheld/bin" plat=/usr/lib/autostart/quirks/platforms/TESTSOC/bin
  trap 'rm -rf "/usr/lib/autostart/quirks/devices/Test Handheld" /usr/lib/autostart/quirks/platforms/TESTSOC /tmp/led.log' EXIT
  export QUIRK_DEVICE="Test Handheld" HW_DEVICE=TESTSOC
  for script in ledcontrol battery_led_status; do
    rm -f /tmp/led.log
    sh "${SYSUTILS}/${script}" red max </dev/null || fail "${script} without quirks failed"
    [ -e /tmp/led.log ] && fail "${script} ran something without quirks"
    stub "${plat}/${script}" <<'EOF'
#!/bin/sh
echo "$0 $*" >>/tmp/led.log
EOF
    sh "${SYSUTILS}/${script}" red max </dev/null
    assert_eq "$(cat /tmp/led.log)" "${plat}/${script} red max" "${script} platform quirk"
    rm -f /tmp/led.log
    stub "${dev}/${script}" <<'EOF'
#!/bin/sh
echo "$0 $*" >>/tmp/led.log
EOF
    sh "${SYSUTILS}/${script}" red max </dev/null
    assert_eq "$(cat /tmp/led.log)" "${dev}/${script} red max" "${script} device quirk wins"
  done
}

test_rk3566_ledcontrol() {
  local args leds color bright led got
  trap 'umount /sys/class; rm -rf /storage/.config' EXIT
  fake /sys/class
  for led in green:power red:status amber:charging; do
    mkdir -p /sys/class/leds/${led}
    echo 0 >/sys/class/leds/${led}/brightness
  done
  settings
  while IFS='|' read -r args leds color bright; do
    sh "${QUIRKS}/platforms/RK3566/bin/ledcontrol" ${args} </dev/null >/dev/null 2>&1
    got=$(for led in green:power red:status amber:charging; do cat /sys/class/leds/${led}/brightness; done | tr '\n' ' ')
    assert_eq "${got% }" "${leds}" "ledcontrol ${args}: green red amber"
    assert_eq "$(setting led.color)" "${color}" "ledcontrol ${args}: led.color"
    assert_eq "$(setting led.brightness)" "${bright}" "ledcontrol ${args}: led.brightness"
  done <<'EOF'
red|0 255 0|red|max
green mid|63 0 0|green|mid
charging|0 63 0|green|mid
discharging|63 0 0|green|mid
amber min|0 0 15|amber|min
off|0 0 0|off|min
charging|0 0 0|off|min
default|15 0 0||min
poweroff|0 0 0||min
EOF
}

test_sm6115_battery_led_colours() {
  local cap status bright rgb side
  trap 'umount /sys/class /sys/devices/platform; unstub /usr/bin/sleep; rm -rf /storage/.config' EXIT
  fake /sys/class
  fake /sys/devices/platform
  mkdir -p /sys/class/power_supply/battery
  for side in l r; do mkdir -p /sys/devices/platform/multi-led-${side}/leds/rgb:${side}; done
  stub /usr/bin/sleep <<'EOF'
#!/bin/sh
sed -i 's/^led.color=battery$/led.color=off/' /storage/.config/system/configs/system.cfg
EOF
  while IFS='|' read -r cap status bright rgb; do
    settings led.color=battery
    echo "${cap}" >/sys/class/power_supply/battery/capacity
    echo "${status}" >/sys/class/power_supply/battery/status
    for side in l r; do
      echo unset >/sys/devices/platform/multi-led-${side}/leds/rgb:${side}/brightness
      echo unset >/sys/devices/platform/multi-led-${side}/leds/rgb:${side}/multi_intensity
    done
    timeout 5 sh "${QUIRKS}/platforms/SM6115/bin/battery_led_status" </dev/null >/dev/null 2>&1
    for side in l r; do
      assert_eq "$(cat /sys/devices/platform/multi-led-${side}/leds/rgb:${side}/brightness)" "${bright}" "${cap}% ${status} ${side}"
      assert_eq "$(cat /sys/devices/platform/multi-led-${side}/leds/rgb:${side}/multi_intensity)" "${rgb}" "${cap}% ${status} ${side}"
    done
  done <<'EOF'
80|Discharging|255|0 255 0
35|Discharging|255|255 125 0
25|Discharging|255|255 20 0
15|Discharging|255|255 0 0
50|Charging|255|255 20 0
97|Full|255|0 255 0
EOF
}

test_memory_manager_auto_sizing() {
  local kb tier swap resume mb
  trap 'umount /proc/meminfo; rm -rf /storage/.config' EXIT
  : >meminfo
  mount --bind "${PWD}/meminfo" /proc/meminfo || fail "cannot bind a fake /proc/meminfo"
  while read -r kb tier swap resume; do
    mb=$((kb / 1024))
    meminfo "${kb}"
    swap_conf 'ZRAM_SIZE="Auto"' 'SWAP_FILE_SIZE="Auto"'
    assert_eq "$(bash "${SCRIPTS}/rocknix-memory-manager" --json </dev/null 2>/dev/null |
      jq -r '"\(.ram_total_mb) \(.tier_ram) \(.zram.size_mb) \(.swap.size_mb)"')" \
      "${mb} ${tier} ${mb} ${swap}" "MemTotal ${kb} kB"
    assert_eq "$(bash "${SCRIPTS}/rocknix-memory-manager" --swap-size Resume --json </dev/null 2>/dev/null |
      jq -r .swap.size_mb)" "${resume}" "resume swap for MemTotal ${kb} kB"
    swap_conf 'ZRAM_SIZE="50%"'
    assert_eq "$(bash "${SCRIPTS}/rocknix-memory-manager" --json </dev/null 2>/dev/null | jq -r .zram.size_mb)" \
      "$((mb / 2))" "zram at 50% for MemTotal ${kb} kB"
  done <<'EOF'
1001772 low 978 1490
1983616 low 1937 2449
3911852 mid 2048 4332
7834172 mid 2048 8162
11727148 high 2048 11964
EOF
}

test_memory_manager_options_persist() {
  trap 'rm -rf /storage/.config' EXIT
  swap_conf 'ZRAM_SIZE="Auto"'
  assert_eq "$(bash "${SCRIPTS}/rocknix-memory-manager" --zram-size 512 --swap-size 0 --json </dev/null 2>/dev/null |
    jq -r '"\(.zram.size_mb) \(.swap.size_mb)"')" "512 0" "explicit sizes"
  assert_eq "$(bash "${SCRIPTS}/rocknix-memory-manager" --zram-size 768 --ksm disable --json </dev/null 2>/dev/null |
    jq -r .zram.size_mb)" "768" "changed zram size"
  assert_eq "$(sort /storage/.config/swap.conf | tr '\n' ' ')" 'KSM_ENABLE="disable" SWAP_FILE_SIZE="0" ZRAM_SIZE="768" ' \
    "swap.conf"
  swap_conf 'ZRAM_SIZE="lots"' 'SWAP_FILE_SIZE="-1"'
  assert_eq "$(bash "${SCRIPTS}/rocknix-memory-manager" --json </dev/null 2>/dev/null |
    jq -r '"\(.zram.size_mb) \(.swap.size_mb)"')" "0 0" "invalid sizes turn zram and swap off"
}

test_memory_manager_soc_tier() {
  local device tier
  trap 'unstub /etc/os-release; rm -rf /storage/.config' EXIT
  cp /etc/os-release release
  swap_conf
  while read -r device tier; do
    hw_device "${device}"
    assert_eq "$(bash "${SCRIPTS}/rocknix-memory-manager" --json </dev/null 2>/dev/null | jq -r .tier_soc)" "${tier}" \
      "${device}"
  done <<'EOF'
RK3326 standard
H700 standard
RK3566 standard
RK3576 standard
RK3399 high
RK3588 high
S922X high
SM4450 high
SM6115 high
SM8250 high
SM8650 high
EOF
}

test_memory_manager_tuning_by_tier() {
  local kb device wsf compaction overcommit ksm f log
  trap 'umount /proc/meminfo /sys/kernel/mm; unstub /usr/bin/sysctl /usr/sbin/sysctl /etc/os-release; rm -rf /storage/.config /tmp/sysctl.log' EXIT
  for f in /usr/bin/sysctl /usr/sbin/sysctl; do
    stub ${f} <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/sysctl.log
EOF
  done
  cp /etc/os-release release
  fake /sys/kernel/mm
  mkdir -p /sys/kernel/mm/ksm
  : >meminfo
  mount --bind "${PWD}/meminfo" /proc/meminfo || fail "cannot bind a fake /proc/meminfo"
  while IFS='|' read -r kb device wsf compaction overcommit ksm; do
    meminfo "${kb}"
    hw_device "${device}"
    swap_conf 'ZRAM_SIZE="0"' 'SWAP_FILE_SIZE="0"'
    for f in run sleep_millisecs pages_to_scan; do echo 0 >/sys/kernel/mm/ksm/${f}; done
    rm -f /tmp/sysctl.log
    bash "${SCRIPTS}/rocknix-memory-manager" --setup </dev/null >/dev/null 2>&1
    log=$(cat /tmp/sysctl.log 2>/dev/null)
    assert_contains "${log}" "-w vm.watermark_scale_factor=${wsf}" "${device} ${kb} kB"
    assert_contains "${log}" "-w vm.compaction_proactiveness=${compaction}" "${device} ${kb} kB"
    assert_contains "${log}" "-w vm.overcommit_memory=${overcommit}" "${device} ${kb} kB"
    assert_eq "$(cat /sys/kernel/mm/ksm/run /sys/kernel/mm/ksm/sleep_millisecs /sys/kernel/mm/ksm/pages_to_scan | tr '\n' ' ')" \
      "${ksm} " "${device} ${kb} kB ksm run, sleep, pages"
  done <<'EOF'
1001772|RK3326|10|10|0|1 500 100
1983616|S922X|10|40|1|1 200 200
3911852|RK3566|100|20|0|1 1000 100
7834172|SM8250|100|40|1|1 1000 100
15610396|SM8650|100|40|1|1 3000 100
EOF
  swap_conf 'ZRAM_SIZE="0"' 'SWAP_FILE_SIZE="0"' 'KSM_ENABLE="disable"' 'VM_OVERCOMMIT="2"' 'VM_COMPACTION="5"'
  echo 1 >/sys/kernel/mm/ksm/run
  rm -f /tmp/sysctl.log
  bash "${SCRIPTS}/rocknix-memory-manager" --setup </dev/null >/dev/null 2>&1
  assert_eq "$(cat /sys/kernel/mm/ksm/run)" "0" "KSM_ENABLE=disable"
  assert_contains "$(cat /tmp/sysctl.log)" "-w vm.overcommit_memory=2" "VM_OVERCOMMIT=2"
  assert_contains "$(cat /tmp/sysctl.log)" "-w vm.compaction_proactiveness=5" "VM_COMPACTION=5"
}
