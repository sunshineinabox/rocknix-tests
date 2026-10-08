# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PACKAGES=${REPO}/projects/ROCKNIX/packages
SETUP=${PACKAGES}/sysutils/systemd/scripts
FUNCTIONS=${PACKAGES}/rocknix/profile.d/001-functions
POST_UPDATE=${PACKAGES}/rocknix/sources/post-update
FACTORYRESET=${PACKAGES}/rocknix/sources/scripts/factoryreset
CFG=/storage/.config/system/configs/system.cfg
POWER_CMDS="systemctl swapoff umount i2cget i2cset"

wipe_storage() {
  rm -rf /storage/* /storage/.[!.]* /storage/..?*
}

fresh_storage() {
  wipe_storage
  systemd-tmpfiles --create --prefix=/storage >/dev/null 2>&1
  mkdir -p /var/log
}

populated_storage() {
  fresh_storage
  cp -a /usr/config/. /storage/.config/
  touch /storage/.configured
}

snapshot() {
  (cd /storage && find . -exec stat -c '%N %s %Y %i' {} + | sort)
}

tree_listing() {
  (cd "$1" && { find . -type f -exec stat -c '%n %s' {} +; find . ! -type f; } | sort)
}

log_ldconfig() {
  rm -f /tmp/ldconfig.log
  stub /usr/bin/ldconfig <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/ldconfig.log
exec /.stubs/orig/usr/bin/ldconfig "$@" >/dev/null 2>&1
EOF
}

use_repo_functions() {
  stub /etc/profile.d/001-functions <"${FUNCTIONS}"
}

run_userconfig() {
  bash "${SETUP}/userconfig-setup" >/dev/null 2>&1
}

userconfig_fixture() {
  fresh_storage
  trap 'unstub /etc/profile.d/001-functions /usr/bin/ldconfig; wipe_storage' EXIT
  use_repo_functions
  log_ldconfig
}

log_power() {
  local c path
  rm -f /tmp/power.log
  for c in ${POWER_CMDS}; do
    path=$(command -v ${c} || echo /usr/sbin/${c})
    stub "${path}" <<EOF
#!/bin/sh
echo "${c} \$*" >>/tmp/power.log
EOF
    POWER_STUBS="${POWER_STUBS} ${path}"
  done
}

reset_fixture() {
  populated_storage
  trap 'unstub ${POWER_STUBS}; wipe_storage' EXIT
  log_power
}

post_update_fixture() {
  populated_storage
  trap 'unstub /usr/bin/ldconfig; wipe_storage' EXIT
  log_ldconfig
}

hw_id_present() {
  local f
  for f in /sys/bus/nvmem/devices/sunxi-sid0/nvmem /sys/bus/nvmem/devices/rockchip-efuse0/nvmem \
    /sys/bus/nvmem/devices/rockchip-otp0/nvmem /sys/bus/platform/devices/secure-monitor/serial \
    /sys/devices/soc0/serial_number; do
    [ -s "${f}" ] && return 0
  done
  return 1
}

test_userconfig_first_boot_populates_storage() {
  local missing f
  userconfig_fixture
  mkdir -p /storage/.config/retroarch
  echo user=1 >/storage/.config/retroarch/retroarch.cfg
  run_userconfig
  [ -e /storage/.configured ] || fail "no /storage/.configured"
  cmp -s "${CFG}" /usr/config/system/configs/system.cfg || fail "system.cfg is not the default"
  assert_eq "$(cat /storage/.config/retroarch/retroarch.cfg)" "user=1" "existing file"
  missing=$( (cd /usr/config && find . | sort) | grep -vxFf <(cd /storage/.config && find .) |
    grep -vE '/es_(features|systems)\.cfg$')
  [ -z "${missing}" ] || fail "not copied from /usr/config:"$'\n'"${missing}"
  if [ -e /usr/bin/emulationstation ]; then
    for f in es_features.cfg es_systems.cfg; do
      assert_eq "$(readlink /storage/.config/emulationstation/${f})" "/usr/config/emulationstation/${f}" "${f}"
    done
    assert_eq "$(readlink /storage/.config/SDL-GameControllerDB/gamecontrollerdb.txt)" \
      "/usr/config/SDL-GameControllerDB/gamecontrollerdb.txt" "controller database"
    assert_eq "$(readlink /storage/.config/emulationstation/themes/system-theme)" \
      "/usr/share/themes/es-theme-art-book-next" "system theme"
  fi
  [ -d /storage/.config/modprobe.d ] || fail "no modprobe.d"
  assert_eq "$(cat /tmp/ldconfig.log)" "-X" "ldconfig"
  [ -s /storage/.cache/ld.so.cache ] || fail "no library cache"
  assert_eq "$(cat /storage/.cache/ld.so.cache.osstamp)" "$(stat -c %Y /etc/os-release)" "library cache stamp"
}

test_userconfig_second_boot_keeps_user_changes() {
  local before
  userconfig_fixture
  run_userconfig
  echo user.key=1 >>"${CFG}"
  echo custom=1 >/storage/.config/retroarch/retroarch.cfg
  rm -f /storage/.config/retroarch/retroarch-core-options.cfg
  mkdir -p /storage/.config/mine
  echo mine >/storage/.config/mine/file
  before=$(snapshot)
  rm -f /tmp/ldconfig.log
  run_userconfig
  assert_eq "$(snapshot)" "${before}" "second boot changed /storage"
  [ ! -e /tmp/ldconfig.log ] || fail "ldconfig ran again: $(cat /tmp/ldconfig.log)"
}

test_userconfig_applies_platform_quirk_config() {
  local quirk
  quirk=/usr/lib/autostart/quirks/platforms/$(. /etc/os-release; echo "${HW_DEVICE}")/config
  [ ! -e "${quirk}" ] || skip "${quirk} ships in this image"
  userconfig_fixture
  trap "rm -rf '${quirk}'; unstub /etc/profile.d/001-functions /usr/bin/ldconfig; wipe_storage" EXIT
  mkdir -p "${quirk}/retroarch" "${quirk}/quirktest"
  echo quirk=1 >"${quirk}/retroarch/retroarch.cfg"
  echo quirk >"${quirk}/quirktest/file"
  run_userconfig
  assert_eq "$(cat /storage/.config/retroarch/retroarch.cfg)" "quirk=1" "platform file over the default"
  assert_eq "$(cat /storage/.config/quirktest/file)" "quirk" "platform-only file"
  cmp -s /storage/.config/retroarch/retroarch-core-options.cfg /usr/config/retroarch/retroarch-core-options.cfg ||
    fail "default next to the platform file"
}

test_userconfig_rebuilds_library_cache_after_update() {
  userconfig_fixture
  run_userconfig
  echo 1 >/storage/.cache/ld.so.cache.osstamp
  rm -f /tmp/ldconfig.log
  run_userconfig
  assert_eq "$(cat /tmp/ldconfig.log)" "-X" "ldconfig after an OS update"
  assert_eq "$(cat /storage/.cache/ld.so.cache.osstamp)" "$(stat -c %Y /etc/os-release)" "stamp refreshed"
  rm -f /storage/.cache/ld.so.cache /tmp/ldconfig.log
  run_userconfig
  assert_eq "$(cat /tmp/ldconfig.log)" "-X" "ldconfig for a missing cache"
  [ -s /storage/.cache/ld.so.cache ] || fail "no library cache"
}

test_usercache_setup_seeds_cache() {
  fresh_storage
  trap wipe_storage EXIT
  rm -rf /storage/.cache/services
  echo bogus >/storage/.cache/services
  sh "${SETUP}/usercache-setup"
  [ -d /storage/.cache/services ] || fail "services file not replaced by a directory"
  cmp -s /storage/.cache/shadow /usr/cache/shadow || fail "shadow not seeded"
  assert_eq "$(stat -c %a /storage/.cache/shadow)" "0" "shadow mode"
}

test_usercache_setup_keeps_root_password() {
  local root='root:$6$saltsalt$userhash:19000:0:99999:7:::'
  fresh_storage
  trap wipe_storage EXIT
  grep -q '^root:' /usr/cache/shadow || skip "no root entry in /usr/cache/shadow"
  { echo "${root}"; echo 'olduser:!:19000::::::'; } >/storage/.cache/shadow
  sh "${SETUP}/usercache-setup"
  assert_eq "$(grep '^root:' /storage/.cache/shadow)" "${root}" "root entry"
  assert_eq "$(grep -v '^root:' /storage/.cache/shadow)" "$(grep -v '^root:' /usr/cache/shadow)" "other entries"
  assert_eq "$(stat -c %a /storage/.cache/shadow)" "0" "shadow mode"
  echo garbage >/storage/.cache/shadow
  sh "${SETUP}/usercache-setup"
  cmp -s /storage/.cache/shadow /usr/cache/shadow || fail "shadow without root not replaced"
}

test_machine_id_generated_once_and_kept() {
  local id
  hw_id_present && skip "a hardware id source is visible in this container"
  fresh_storage
  trap wipe_storage EXIT
  echo stale >/storage/.cache/machine-id
  bash "${SETUP}/systemd-machine-id-setup" >/dev/null 2>&1
  id=$(cat /storage/.cache/systemd-machine-id)
  [[ ${id} =~ ^[0-9a-f]{32}$ ]] || fail "not a machine id: [${id}]"
  [ ! -e /storage/.cache/machine-id ] || fail "old machine-id kept"
  bash "${SETUP}/systemd-machine-id-setup" >/dev/null 2>&1
  assert_eq "$(cat /storage/.cache/systemd-machine-id)" "${id}" "machine id on the next boot"
  echo 0123456789abcdef0123456789ABCDEF >/storage/.cache/systemd-machine-id
  bash "${SETUP}/systemd-machine-id-setup" >/dev/null 2>&1
  id=$(cat /storage/.cache/systemd-machine-id)
  [[ ${id} =~ ^[0-9a-f]{32}$ ]] || fail "invalid machine id not replaced: [${id}]"
  rm -rf /storage/.cache
  bash "${SETUP}/systemd-machine-id-setup" >/dev/null 2>&1
  [[ $(cat /storage/.cache/systemd-machine-id) =~ ^[0-9a-f]{32}$ ]] || fail "no machine id without /storage/.cache"
}

test_post_update_resyncs_managed_configs() {
  local module f
  post_update_fixture
  module=$(cd /usr/config && find modules -type f | sort | head -n 1)
  echo old >/storage/.cache/ld.so.cache
  echo user >/storage/.config/emulationstation/es_systems.cfg
  echo user >>/storage/.config/retroarch/retroarch-core-options.cfg
  echo user >>"/storage/.config/${module}"
  echo user >"/storage/.config/modules/My Tool.sh"
  touch /storage/.config/emulationstation/resources/logo.png
  echo user >/storage/.config/melonDS/user.ini
  echo stray >/storage/.config/system/stray.cfg
  rm -rf /storage/.config/emulationstation/locale
  mkdir -p /storage/.config/emulationstation/locale/xx
  bash "${POST_UPDATE}" >/dev/null 2>&1
  assert_eq "$(cat /tmp/ldconfig.log)" "-X" "ldconfig"
  [ -s /storage/.cache/ld.so.cache ] && [ "$(cat /storage/.cache/ld.so.cache)" != old ] ||
    fail "library cache not rebuilt"
  assert_eq "$(cat /storage/.config/emulationstation/last_es_systems.cfg)" "user" "es_systems.cfg kept aside"
  for f in es_features.cfg es_systems.cfg; do
    assert_eq "$(readlink /storage/.config/emulationstation/${f})" "/usr/config/emulationstation/${f}" "${f}"
  done
  cmp -s /storage/.config/retroarch/retroarch-core-options.cfg /usr/config/retroarch/retroarch-core-options.cfg ||
    fail "retroarch-core-options.cfg not reset"
  cmp -s "/storage/.config/${module}" "/usr/config/${module}" || fail "${module} not refreshed"
  [ -f "/storage/.config/modules/My Tool.sh" ] || fail "user module removed"
  [ ! -e /storage/.config/emulationstation/resources/logo.png ] || fail "logo.png kept"
  [ ! -e /storage/.config/melonDS/user.ini ] || fail "melonDS not replaced"
  cmp -s /storage/.config/melonDS/melonDS.ini /usr/config/melonDS/melonDS.ini || fail "melonDS.ini not restored"
  [ ! -e /storage/.config/system/stray.cfg ] || fail "stray file in /storage/.config/system kept"
  assert_eq "$(readlink /storage/.config/emulationstation/locale)" "/usr/share/locale" "ES locale"
}

test_post_update_keeps_user_settings() {
  local game1 game2
  post_update_fixture
  game1=$(cd /usr/config && find game -type f | sort | sed -n 1p)
  game2=$(cd /usr/config && find game -type f | sort | sed -n 2p)
  echo user.key=1 >>"${CFG}"
  echo notes >/storage/.config/system/configs/notes.txt
  echo custom=1 >>/storage/.config/retroarch/retroarch.cfg
  echo user >>"/storage/.config/${game1}"
  rm -f "/storage/.config/${game2}"
  echo mine >/storage/.config/mine.cfg
  bash "${POST_UPDATE}" >/dev/null 2>&1
  grep -qx user.key=1 "${CFG}" || fail "user setting lost"
  [ -f /storage/.config/system/configs/notes.txt ] || fail "file in configs removed"
  assert_eq "$(tail -n 1 /storage/.config/retroarch/retroarch.cfg)" "custom=1" "retroarch.cfg"
  assert_eq "$(tail -n 1 "/storage/.config/${game1}")" "user" "${game1}"
  cmp -s "/storage/.config/${game2}" "/usr/config/${game2}" || fail "${game2} not restored"
  [ -f /storage/.config/mine.cfg ] || fail "user file removed"
}

test_post_update_settings_migrations() {
  local d=/storage/.config/sysctl.d
  post_update_fixture
  sed -i '/^system.batteryplus.enabled=/d' "${CFG}"
  echo system.suspend.dpms=1 >>"${CFG}"
  mkdir -p /storage/roms/bios/aethersx2/bios "${d}"
  echo bios >/storage/roms/bios/aethersx2/bios/scph39001.bin
  printf '%s\n' vm.swappiness=1 kernel.nmi_watchdog=0 vm.laptop_mode=5 vm.dirty_writeback_centisecs=1500 \
    >"${d}/rocknix.conf"
  echo 'net.ipv4.ip_forward = 0' >"${d}/99-rocknix-networking.conf"
  echo vm.swappiness=10 >"${d}/user.conf"
  bash "${POST_UPDATE}" >/dev/null 2>&1
  assert_eq "$(grep '^system.batteryplus' "${CFG}")" "system.batteryplus.enabled=1" "batteryplus flag added"
  grep -q system.suspend.dpms "${CFG}" && fail "system.suspend.dpms kept"
  assert_eq "$(cat /storage/roms/bios/armsx2/scph39001.bin 2>&1)" "bios" "aethersx2 bios copied for armsx2"
  [ ! -e "${d}/rocknix.conf" ] || fail "untouched rocknix.conf kept"
  [ -f "${d}/99-rocknix-networking.conf" ] || fail "edited 99-rocknix-networking.conf removed"
  [ -f "${d}/user.conf" ] || fail "user sysctl removed"
  sed -i 's/^system.batteryplus.enabled=.*/system.batteryplus.enabled=0/' "${CFG}"
  bash "${POST_UPDATE}" >/dev/null 2>&1
  assert_eq "$(grep '^system.batteryplus' "${CFG}")" "system.batteryplus.enabled=0" "batteryplus choice kept"
}

test_post_update_migrates_dolphin_profiles_once() {
  local d=/storage/.config/dolphin-emu f
  post_update_fixture
  printf '[Profile]\nDevice = evdev/0/Microsoft X-Box 360 pad\n' >"${d}/GamecubeControllerProfiles/GCPadNew.ini.south"
  echo legacy >"${d}/GamecubeControllerProfiles/GCPadNew.ini.east"
  echo evdev >"${d}/GamecubeControllerProfiles/GCPadNew.ini.custom"
  echo evdev >"${d}/WiiControllerProfiles/custom.ini"
  echo pad >"${d}/GCPadNew.ini"
  echo wiimote >"${d}/WiimoteNew.ini"
  echo user >>"${d}/Hotkeys.ini"
  bash "${POST_UPDATE}" >/dev/null 2>&1
  assert_eq "$(cat "${d}/GamecubeControllerProfiles/GCPadNew.ini.custom.evdev")" "evdev" "GC custom profile backup"
  assert_eq "$(cat "${d}/WiiControllerProfiles/custom.ini.evdev")" "evdev" "Wii custom profile backup"
  for f in GamecubeControllerProfiles/GCPadNew.ini.custom WiiControllerProfiles/custom.ini GCPadNew.ini \
    WiimoteNew.ini GamecubeControllerProfiles/GCPadNew.ini.south GamecubeControllerProfiles/GCPadNew.ini.east; do
    [ ! -e "${d}/${f}" ] || fail "${f} kept"
  done
  cmp -s "${d}/Hotkeys.ini" /usr/config/dolphin-emu/Hotkeys.ini || fail "Hotkeys.ini not refreshed"
  echo sdl >"${d}/GamecubeControllerProfiles/GCPadNew.ini.custom"
  echo pad >"${d}/GCPadNew.ini"
  bash "${POST_UPDATE}" >/dev/null 2>&1
  assert_eq "$(cat "${d}/GamecubeControllerProfiles/GCPadNew.ini.custom")" "sdl" "new custom profile"
  assert_eq "$(cat "${d}/GamecubeControllerProfiles/GCPadNew.ini.custom.evdev")" "evdev" "backup on the next update"
  [ -f "${d}/GCPadNew.ini" ] || fail "GCPadNew.ini removed on the next update"
}

test_factoryreset_retroarch() {
  reset_fixture
  echo user >>/storage/.config/retroarch/retroarch.cfg
  mkdir -p /storage/.config/retroarch/config/snes
  echo override >/storage/.config/retroarch/config/snes/snes.cfg
  bash "${FACTORYRESET}" retroarch
  cmp -s /storage/.config/retroarch/retroarch.cfg /usr/config/retroarch/retroarch.cfg || fail "retroarch.cfg not reset"
  [ -f /storage/.config/retroarch/config/snes/snes.cfg ] || fail "core override removed"
  [ ! -e /tmp/power.log ] || fail "unexpected: $(cat /tmp/power.log)"
}

test_factoryreset_retroarch_full() {
  reset_fixture
  echo user >>/storage/.config/retroarch/retroarch.cfg
  mkdir -p /storage/.config/retroarch/config/snes
  echo override >/storage/.config/retroarch/config/snes/snes.cfg
  echo user >/storage/.config/mednafen/mednafen.cfg
  bash "${FACTORYRESET}" retroarch-full
  assert_eq "$(tree_listing /storage/.config/retroarch)" "$(tree_listing /usr/config/retroarch)" "retroarch tree"
  cmp -s /storage/.config/retroarch/retroarch.cfg /usr/config/retroarch/retroarch.cfg || fail "retroarch.cfg not reset"
  [ -f /storage/.config/mednafen/mednafen.cfg ] || fail "mednafen.cfg removed"
  [ ! -e /tmp/power.log ] || fail "unexpected: $(cat /tmp/power.log)"
}

test_factoryreset_mednafen() {
  reset_fixture
  echo user >/storage/.config/mednafen/mednafen.cfg
  echo save >/storage/.config/mednafen/game.mcs
  bash "${FACTORYRESET}" mednafen
  [ ! -e /storage/.config/mednafen/mednafen.cfg ] || fail "mednafen.cfg kept"
  [ -f /storage/.config/mednafen/game.mcs ] || fail "other mednafen files removed"
  [ -f /storage/.config/mednafen/mednafen.template ] || fail "template removed"
}

test_factoryreset_standalone() {
  local d dirs="aethersx2 amiberry dolphin-emu drastic duckstation flycast gzdoom hatari melonDS openbor ppsspp azahar rpcs3"
  reset_fixture
  for d in ${dirs}; do
    mkdir -p "/storage/.config/${d}"
    echo user >"/storage/.config/${d}/user-marker"
  done
  echo user >>/storage/.config/retroarch/retroarch.cfg
  bash "${FACTORYRESET}" standalone 2>/dev/null
  for d in ${dirs}; do
    [ -d "/usr/config/${d}" ] || continue
    assert_eq "$(tree_listing "/storage/.config/${d}")" "$(tree_listing "/usr/config/${d}")" "${d}"
  done
  assert_eq "$(tail -n 1 /storage/.config/retroarch/retroarch.cfg)" "user" "retroarch.cfg"
  [ ! -e /tmp/power.log ] || fail "unexpected: $(cat /tmp/power.log)"
}

test_factoryreset_portmaster() {
  reset_fixture
  [ -f /usr/config/PortMaster/release/PortMaster.zip ] || skip "no PortMaster.zip in this image"
  mkdir -p /storage/roms/ports/PortMaster
  echo old >/storage/roms/ports/PortMaster/stale.txt
  echo game >/storage/roms/ports/Game.sh
  echo user >/storage/.config/PortMaster/user.txt
  bash "${FACTORYRESET}" portmaster >/dev/null 2>&1
  [ ! -e /storage/roms/ports/PortMaster/stale.txt ] || fail "old PortMaster files kept"
  [[ $(stat -c %A /storage/roms/ports/PortMaster/PortMaster.sh 2>&1) == -rwx* ]] || fail "PortMaster.sh not installed"
  [ -f /storage/roms/ports/Game.sh ] || fail "other ports removed"
  assert_eq "$(tree_listing /storage/.config/PortMaster)" "$(tree_listing /usr/config/PortMaster)" "PortMaster config"
}

test_factoryreset_overlays() {
  local dirs upper
  reset_fixture
  dirs=$(sed -n 's/^Options=.*upperdir=\([^,]*\).*/\1/p' /usr/lib/systemd/system/tmp-*.mount)
  [ -n "${dirs}" ] || skip "no overlay mount units"
  for upper in ${dirs}; do
    mkdir -p "${upper}"
    echo user >"${upper}/file"
  done
  mkdir -p /storage/roms /storage/remappings
  echo game >/storage/roms/game.sfc
  echo remap >/storage/remappings/game.rmp
  bash "${FACTORYRESET}" overlays
  for upper in ${dirs}; do
    [ ! -e "${upper}" ] || fail "${upper} kept"
  done
  [ -f /storage/roms/game.sfc ] && [ -f /storage/remappings/game.rmp ] && [ -f "${CFG}" ] ||
    fail "files outside the overlays removed"
  assert_eq "$(cat /tmp/power.log)" "systemctl reboot" "power"
}

test_factoryreset_audio() {
  local f
  reset_fixture
  mkdir -p /storage/.local/state/wireplumber /storage/.local/share/app /storage/.config/pulse
  echo state >/storage/.local/state/wireplumber/default-nodes
  echo keep >/storage/.local/share/app/keep
  echo cookie >/storage/.config/pulse/cookie
  echo alsa >/storage/asound.state
  bash "${FACTORYRESET}" audio
  for f in /storage/.local/state /storage/.config/pulse /storage/asound.state; do
    [ ! -e "${f}" ] || fail "${f} kept"
  done
  [ -f /storage/.local/share/app/keep ] && [ -f "${CFG}" ] || fail "unrelated files removed"
  assert_eq "$(cat /tmp/power.log)" \
    $'systemctl stop pipewire-pulse pipewire-pulse.socket pipewire pipewire.socket wireplumber\nsystemctl reboot' "power"
}

test_factoryreset_all() {
  reset_fixture
  mkdir -p /storage/roms/snes /storage/games-internal/pc /storage/games-external/usb /storage/backup /storage/bin \
    /storage/.update /storage/.ssh
  echo update >/storage/.update/ROCKNIX-SM8250.aarch64.tar
  echo game >/storage/roms/snes/game.sfc
  echo game >/storage/games-internal/pc/game.exe
  echo game >/storage/games-external/usb/game.iso
  echo key >/storage/.ssh/authorized_keys
  echo backup >/storage/backup/backup.zip
  echo tool >/storage/bin/tool
  bash "${FACTORYRESET}" ALL
  assert_eq "$(cd /storage && find . | sort)" "$(printf '%s\n' . ./.config ./.update ./.update/ROCKNIX-SM8250.aarch64.tar \
    ./games-external ./games-external/usb ./games-external/usb/game.iso ./games-internal ./games-internal/pc \
    ./games-internal/pc/game.exe ./roms ./roms/snes ./roms/snes/game.sfc | sort)" "files left"
  assert_eq "$(cat /tmp/power.log)" \
    $'swapoff -a\numount /storage/roms\numount /storage/games-external\nsystemctl reboot' "power"
}

test_factoryreset_without_target_changes_nothing() {
  local before mode
  ls -d /sys/bus/i2c/devices/*-0020 >/dev/null 2>&1 && skip "i2c devices at 0x20 visible in this container"
  reset_fixture
  before=$(snapshot)
  for mode in rk817-fuelgauge bogus ""; do
    bash "${FACTORYRESET}" "${mode}"
  done
  assert_eq "$(snapshot)" "${before}" "/storage changed"
  [ ! -e /tmp/power.log ] || fail "unexpected: $(cat /tmp/power.log)"
}
