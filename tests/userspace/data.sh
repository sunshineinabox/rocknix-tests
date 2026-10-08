# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

SCRIPTS=${REPO}/projects/ROCKNIX/packages/rocknix/sources/scripts
SYSCFG=/storage/.config/system/configs/system.cfg
BACKUP_PATHS="/storage/.config/system /storage/.config/retroarch /storage/.config/ppsspp /storage/.config/mpv
  /storage/.config/fancontrol.conf /storage/.config/backuptool.conf /storage/.cache/bluetooth /storage/.emulationstation
  /storage/roms"

argv_stub() {
  stub "$1" <<EOF
#!/bin/sh
{ for a in "\$@"; do printf '[%s]' "\$a"; done; echo; } >>/tmp/$(basename "$1").log
exit 0
EOF
}

settings() {
  mkdir -p "${SYSCFG%/*}"
  printf '%s\n' "$@" >"${SYSCFG}"
}

put() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

backup_file() {
  . /etc/os-release
  echo "/storage/roms/backup/${OS_NAME}_BACKUP.zip"
}

zip_names() {
  python3 -c '
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
bad = z.testzip()
if bad:
    sys.exit("corrupt member " + bad)
print("\n".join(n for n in z.namelist() if not n.endswith("/")))' "$1"
}

backup_setup() {
  trap 'rm -rf ${BACKUP_PATHS}' EXIT
  rm -rf ${BACKUP_PATHS}
  put /storage/.config/system/configs/system.cfg "wifi.ssid=Home"
  put /storage/.config/fancontrol.conf "INTERVAL=10"
  put /storage/.config/retroarch/retroarch.cfg 'video_driver = "gl"'
  put /storage/.config/retroarch/config/Snes9x/Snes9x.opt 'snes9x_overclock = "disabled"'
  put /storage/.config/ppsspp/PSP/SYSTEM/ppsspp.ini "[Graphics]"
  put /storage/.config/mpv/mpv.conf "hwdec=auto"
  put /storage/.cache/bluetooth/11:22:33:44:55:66/settings "[General]"
  put /storage/.emulationstation/es_settings.cfg "<config/>"
  put /storage/.emulationstation/es_input.cfg "<inputList/>"
  put /storage/.emulationstation/es_log.txt "log"
  put /storage/.emulationstation/gamelists/gba/gamelist.xml "<gameList/>"
  put /storage/.emulationstation/scripts/game-start/hook.sh "true"
  put /storage/.emulationstation/themes/es-theme-custom/theme.xml "<theme/>"
  put /storage/.emulationstation/themes/es-theme-art-book-next/theme.xml "<theme/>"
  put /storage/.emulationstation/themes/system-theme/theme.xml "<theme/>"
  put /storage/roms/gba/game.gba "rom"
}

test_backuptool_default_selection() {
  local names f
  backup_setup
  bash "${SCRIPTS}/backuptool" backup >/dev/null 2>&1
  names=$(zip_names "$(backup_file)") || fail "no valid backup archive: ${names}"
  for f in storage/.config/system/configs/system.cfg storage/.config/fancontrol.conf \
    storage/.config/retroarch/retroarch.cfg storage/.config/retroarch/config/Snes9x/Snes9x.opt \
    storage/.config/ppsspp/PSP/SYSTEM/ppsspp.ini storage/.cache/bluetooth/11:22:33:44:55:66/settings \
    storage/.emulationstation/es_settings.cfg storage/.emulationstation/es_input.cfg \
    storage/.emulationstation/scripts/game-start/hook.sh storage/.emulationstation/themes/es-theme-custom/theme.xml; do
    echo "${names}" | grep -qxF "${f}" || fail "backup lacks ${f}"
  done
  for f in storage/.emulationstation/es_log.txt storage/.emulationstation/gamelists/gba/gamelist.xml \
    storage/.emulationstation/themes/es-theme-art-book-next/theme.xml \
    storage/.emulationstation/themes/system-theme/theme.xml storage/roms/gba/game.gba storage/.config/mpv/mpv.conf; do
    echo "${names}" | grep -qxF "${f}" && fail "backup includes ${f}"
  done
  return 0
}

test_backuptool_restore_overwrites() {
  backup_setup
  bash "${SCRIPTS}/backuptool" backup >/dev/null 2>&1
  put /storage/.config/retroarch/retroarch.cfg 'video_driver = "vulkan"'
  rm /storage/.config/ppsspp/PSP/SYSTEM/ppsspp.ini
  put /storage/.config/retroarch/new.cfg "new"
  bash "${SCRIPTS}/backuptool" restore </dev/null >/dev/null 2>&1
  assert_eq "$(cat /storage/.config/retroarch/retroarch.cfg)" 'video_driver = "gl"' "changed file"
  assert_eq "$(cat /storage/.config/ppsspp/PSP/SYSTEM/ppsspp.ini 2>/dev/null)" "[Graphics]" "deleted file"
  assert_eq "$(cat /storage/.config/retroarch/new.cfg)" "new" "file created after the backup"
}

test_backuptool_archives_previous_backup() {
  local first archived
  backup_setup
  bash "${SCRIPTS}/backuptool" backup >/dev/null 2>&1
  first=$(md5sum <"$(backup_file)")
  put /storage/.config/retroarch/retroarch.cfg 'video_driver = "vulkan"'
  bash "${SCRIPTS}/backuptool" backup >/dev/null 2>&1
  archived=$(ls /storage/roms/backup/ARCHIVED_*_BACKUP-*.zip 2>/dev/null)
  [ "$(echo "${archived}" | grep -c .)" -eq 1 ] || fail "expected one archived backup, got [${archived}]"
  assert_eq "$(md5sum <"${archived}")" "${first}" "archived copy of the first backup"
  zip_names "$(backup_file)" >/dev/null || fail "new backup is not a valid archive"
}

test_backuptool_custom_locations() {
  local names
  backup_setup
  put /storage/.config/backuptool.conf 'LOCATIONS=(
  /storage/.config/mpv/*
  /storage/.emulationstation/es_settings.cfg
)'
  bash "${SCRIPTS}/backuptool" backup >/dev/null 2>&1
  names=$(zip_names "$(backup_file)" | sort) || fail "no valid backup archive"
  assert_eq "${names}" "storage/.config/mpv/mpv.conf"$'\n'"storage/.emulationstation/es_settings.cfg"
}

test_backuptool_paths_with_spaces() {
  local names f
  backup_setup
  put "/storage/.config/retroarch/ParaLLEl N64.opt" 'parallel-n64-gfxplugin = "auto"'
  put "/storage/.emulationstation/themes/My Theme/theme.xml" "<theme/>"
  bash "${SCRIPTS}/backuptool" backup >/dev/null 2>&1
  names=$(zip_names "$(backup_file)") || fail "no valid backup archive"
  for f in "storage/.config/retroarch/ParaLLEl N64.opt" "storage/.emulationstation/themes/My Theme/theme.xml"; do
    echo "${names}" | grep -qxF "${f}" || fail "backup lacks ${f}"
  done
  return 0
}

migrate_setup() {
  trap 'unstub /usr/sbin/reboot; rm -rf /storage/games-internal /storage/games-external /tmp/reboot.log' EXIT
  rm -rf /storage/games-internal /storage/games-external /tmp/reboot.log
  mkdir -p /var/log
  argv_stub /usr/sbin/reboot
  put /storage/games-internal/gba/a.gba a
  put "/storage/games-internal/snes/Super Game.sfc" b
  put /storage/games-internal/snes/sub/c.sfc c
  put /storage/games-internal/roms/nes/n.nes n
  put /storage/games-external/psx/p.chd p
  echo | sh "${SCRIPTS}/migrate_roms" >migrate.out 2>&1
}

test_migrate_roms_moves_systems_into_roms() {
  local f
  migrate_setup
  for f in internal/roms/gba/a.gba "internal/roms/snes/Super Game.sfc" internal/roms/snes/sub/c.sfc \
    internal/roms/nes/n.nes external/roms/psx/p.chd; do
    [ -f "/storage/games-${f}" ] || fail "missing /storage/games-${f}"$'\n'"$(find /storage/games-internal /storage/games-external)"
  done
  [ -e /storage/games-internal/gba/a.gba ] && fail "source file left behind"
  return 0
}

test_migrate_roms_cleans_up() {
  migrate_setup
  [ -e /storage/games-internal/gba ] || [ -e /storage/games-external/psx ] &&
    fail "emptied system directories not removed: $(find /storage/games-internal /storage/games-external -type d -empty)"
  [ -n "$(ls -A . | grep -vx migrate.out)" ] && fail "stray files in the working directory: $(ls -A)"
  return 0
}

test_migrate_roms_does_not_reboot() {
  migrate_setup
  [ -e /tmp/reboot.log ] && fail "migrate_roms ran reboot $(grep -c '' /tmp/reboot.log) times"
  return 0
}

rootpass_setup() {
  trap 'unstub /usr/bin/smbpasswd /usr/bin/syncthing /usr/bin/systemctl
    rm -f /storage/.cache/shadow "${SYSCFG}" /tmp/smbpasswd.log /tmp/syncthing.log /tmp/systemctl.log /tmp/systemctl.active' EXIT
  rm -f /tmp/smbpasswd.log /tmp/syncthing.log /tmp/systemctl.log /tmp/systemctl.active
  mkdir -p /storage/.cache
  cp /usr/cache/shadow /storage/.cache/shadow
  chmod 000 /storage/.cache/shadow
  settings "$@"
  stub /usr/bin/smbpasswd <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '[%s]' "$a"; done; echo; cat; } >>/tmp/smbpasswd.log
EOF
  argv_stub /usr/bin/syncthing
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/systemctl.log
if [ "$1" = status ]; then
  echo "* $2.service - $2"
  echo "     Loaded: loaded (/usr/lib/systemd/system/$2.service; enabled; preset: disabled)"
  if grep -qx "$2" /tmp/systemctl.active 2>/dev/null; then
    echo "     Active: active (running) since Thu 2026-10-08 10:00:00 UTC; 1h ago"
  else
    echo "     Active: inactive (dead)"
  fi
fi
exit 0
EOF
}

test_setrootpass_sets_all_passwords() {
  local pass='n3w pass#w0rd&' hash salt
  rootpass_setup 'syncthing.enabled=0' 'simplehttp.enabled=0'
  bash "${SCRIPTS}/setrootpass" "${pass}" >/dev/null 2>&1
  hash=$(awk -F: '/^root:/ {print $2}' /storage/.cache/shadow)
  [ "${hash}" = "$(awk -F: '/^root:/ {print $2}' /usr/cache/shadow)" ] && fail "root password unchanged"
  salt=$(echo "${hash}" | cut -d'$' -f3)
  assert_eq "$(cryptpw -m sha512 -S "${salt}" "${pass}")" "${hash}" "shadow hash of the new password"
  assert_eq "$(grep -v '^root:' /storage/.cache/shadow)" "$(grep -v '^root:' /usr/cache/shadow)" "other accounts"
  assert_eq "$(grep '^root:' /storage/.cache/shadow | cut -d: -f3-)" "$(grep '^root:' /usr/cache/shadow | cut -d: -f3-)" "aging fields"
  assert_eq "$(cat /tmp/smbpasswd.log)" "[-sa][root]"$'\n'"${pass}"$'\n'"${pass}" "samba"
  assert_eq "$(cat /tmp/syncthing.log)" "[generate][--gui-user][root][--gui-password][${pass}]" "syncthing"
  assert_eq "$(grep '^root.password=' "${SYSCFG}")" "root.password=${pass}" "stored setting"
  grep -q restart /tmp/systemctl.log && fail "restarted disabled services: $(cat /tmp/systemctl.log)"
  return 0
}

test_setrootpass_restarts_active_services() {
  rootpass_setup 'syncthing.enabled=1' 'simplehttp.enabled=1'
  printf 'syncthing\nsimple-http-server\n' >/tmp/systemctl.active
  bash "${SCRIPTS}/setrootpass" secret >/dev/null 2>&1
  assert_contains "$(cat /tmp/systemctl.log)" "restart syncthing"
  assert_contains "$(cat /tmp/systemctl.log)" "restart simple-http-server"
  rm -f /tmp/systemctl.log /tmp/systemctl.active
  bash "${SCRIPTS}/setrootpass" secret >/dev/null 2>&1
  grep -q restart /tmp/systemctl.log && fail "restarted inactive services: $(cat /tmp/systemctl.log)"
  return 0
}

test_setrootpass_samba_password_verbatim() {
  local pass='C:\temp\new'
  rootpass_setup
  bash "${SCRIPTS}/setrootpass" "${pass}" >/dev/null 2>&1
  assert_eq "$(cat /tmp/smbpasswd.log)" "[-sa][root]"$'\n'"${pass}"$'\n'"${pass}" "samba password"
}

automount_teardown() {
  unstub /usr/bin/mount /usr/bin/umount /usr/sbin/modprobe /usr/bin/systemd-tmpfiles /usr/sbin/blkid
  rm -rf /storage/games-internal /storage/games-external /storage/roms /storage/.ms_supported /storage/.ms_unsupported
  rm -f "${SYSCFG}" /tmp/mount.log /tmp/umount.log /tmp/modprobe.log /tmp/systemd-tmpfiles.log /tmp/blkid.out
}

automount_setup() {
  trap automount_teardown EXIT
  rm -rf /storage/games-internal /storage/games-external /storage/.ms_supported /storage/.ms_unsupported
  rm -f /tmp/mount.log /tmp/umount.log /tmp/modprobe.log /tmp/systemd-tmpfiles.log /tmp/blkid.out
  mkdir -p /var/log /storage/roms
  settings "$@"
  argv_stub /usr/bin/mount
  argv_stub /usr/bin/umount
  argv_stub /usr/sbin/modprobe
  argv_stub /usr/bin/systemd-tmpfiles
  stub /usr/sbin/blkid <<'EOF'
#!/bin/sh
cat /tmp/blkid.out 2>/dev/null
exit 0
EOF
}

test_automount_disabled_binds_internal() {
  automount_setup 'system.automount=0' 'system.merged.storage=0'
  bash "${SCRIPTS}/automount" >/dev/null 2>&1 || fail "automount failed"
  assert_eq "$(cat /tmp/mount.log)" "[--bind][/storage/games-internal/roms][/storage/roms]"
  [ -d /storage/games-internal/roms ] && [ -d /storage/games-external/roms ] || fail "roms directories not created"
  [ -e /tmp/umount.log ] && fail "unmounted storage with automount off: $(cat /tmp/umount.log)"
  return 0
}

test_automount_merged_storage_layers() {
  automount_setup 'system.automount=0' 'system.merged.storage=1'
  bash "${SCRIPTS}/automount" >/dev/null 2>&1
  assert_eq "$(cat /tmp/mount.log)" "[overlay][-t][overlay][-o][lowerdir=/storage/games-internal/roms,upperdir=/storage/games-external/roms,workdir=/storage/games-external/.tmp/games-workdir][/storage/roms]" "external on top"
  [ -d /storage/games-external/.tmp/games-workdir ] || fail "overlay workdir not created"
  rm -f /tmp/mount.log
  settings 'system.automount=0' 'system.merged.storage=1' 'system.merged.device=internal'
  bash "${SCRIPTS}/automount" >/dev/null 2>&1
  assert_eq "$(cat /tmp/mount.log)" "[overlay][-t][overlay][-o][lowerdir=/storage/games-external/roms,upperdir=/storage/games-internal/roms,workdir=/storage/games-internal/.tmp/games-workdir][/storage/roms]" "internal on top"
  rm -f /tmp/mount.log
  touch /storage/.ms_unsupported
  bash "${SCRIPTS}/automount" >/dev/null 2>&1
  assert_eq "$(cat /tmp/mount.log)" "[--bind][/storage/games-internal/roms][/storage/roms]" "overlay unsupported"
}

test_automount_without_card_uses_internal() {
  mountpoint -q /storage || skip "/storage is not a mount point"
  automount_setup 'system.merged.storage=0'
  bash "${SCRIPTS}/automount" >/dev/null 2>&1
  assert_eq "$(grep '^system.automount=' "${SYSCFG}")" "system.automount=1" "automount enabled by default"
  assert_eq "$(grep '^system.merged.device=' "${SYSCFG}")" "system.merged.device=internal" "merge target"
  assert_contains "$(cat /tmp/umount.log)" "[-f][/storage/games-external]"$'\n'"[-f][/storage/roms]"
  assert_eq "$(cat /tmp/mount.log)" "[--bind][/storage/games-internal/roms][/storage/roms]"
  assert_eq "$(cat /tmp/systemd-tmpfiles.log)" "[--create][/usr/config/system-dirs.conf]" "game directories"
}

test_automount_card_filesystem_selects_mode() {
  automount_setup 'system.automount=1' 'system.merged.storage=1' 'system.gamesdevice=/dev/null'
  printf 'DEVNAME=/dev/null\nTYPE=vfat\n' >/tmp/blkid.out
  touch /storage/.ms_supported
  bash "${SCRIPTS}/automount" >/dev/null 2>&1
  [ -e /storage/.ms_unsupported ] && [ ! -e /storage/.ms_supported ] || fail "vfat card not marked unsupported for overlay"
  assert_eq "$(grep '^system.merged.device=' "${SYSCFG}")" "system.merged.device=external" "merge target"
  assert_eq "$(cat /tmp/mount.log)" "[--bind][/storage/games-external/roms][/storage/roms]" "vfat card"
  rm -f /tmp/mount.log
  printf 'DEVNAME=/dev/null\nTYPE=ext4\n' >/tmp/blkid.out
  bash "${SCRIPTS}/automount" >/dev/null 2>&1
  [ -e /storage/.ms_supported ] && [ ! -e /storage/.ms_unsupported ] || fail "ext4 card not marked supported for overlay"
  assert_eq "$(cat /tmp/mount.log)" "[overlay][-t][overlay][-o][lowerdir=/storage/games-internal/roms,upperdir=/storage/games-external/roms,workdir=/storage/games-external/.tmp/games-workdir][/storage/roms]" "ext4 card"
}

systems_setup() {
  trap 'rm -rf /storage/.config/emulationstation /storage/roms/bios' EXIT
  rm -rf /storage/roms/bios
  mkdir -p /storage/.config/emulationstation /storage/roms/bios
  cat >/storage/.config/emulationstation/es_systems.cfg <<'EOF'
<?xml version="1.0"?>
<systemList>
  <system>
    <name>gb</name>
    <fullname>Nintendo Game Boy</fullname>
    <path>/storage/roms/gb</path>
    <emulators><emulator name="retroarch"><cores><core>gambatte</core><core>mgba</core></cores></emulator></emulators>
  </system>
  <system>
    <name>gba</name>
    <fullname>Nintendo Game Boy Advance</fullname>
    <path>/storage/roms/gba</path>
    <emulators><emulator name="retroarch"><cores><core>mgba</core></cores></emulator></emulators>
  </system>
</systemList>
EOF
  echo "not a bios" >/storage/roms/bios/gba_bios.bin
}

test_systems_reports_configured_systems() {
  local out
  systems_setup
  out=$(python3 "${SCRIPTS}/rocknix-systems") || fail "rocknix-systems failed: ${out}"
  assert_eq "${out}" "> gb
MISSING 32fbbd84168d3482956eb3c5051637f5 bios/gb_bios.bin
> gba
UNTESTED a860e8c0b6d573d191e4ec7db1b1e4f6 bios/gba_bios.bin"
}

test_systems_filter() {
  local out rc
  systems_setup
  assert_eq "$(python3 "${SCRIPTS}/rocknix-systems" --filter GBA)" "> gba
UNTESTED a860e8c0b6d573d191e4ec7db1b1e4f6 bios/gba_bios.bin" "gba"
  assert_eq "$(python3 "${SCRIPTS}/rocknix-systems" --filter dreamcast)" "No missing bios" "system not in es_systems.cfg"
  out=$(python3 "${SCRIPTS}/rocknix-systems" --filter vectrex)
  rc=$?
  assert_eq "${out}" "No system named vectrex found" "unknown system"
  assert_eq "${rc}" 1 "exit status for an unknown system"
}

test_systems_no_filter_and_readme() {
  local readme out
  systems_setup
  readme=$(python3 "${SCRIPTS}/rocknix-systems" --createReadme) || fail "--createReadme failed"
  assert_contains "${readme}" "Nintendo Gameboy Advance:"$'\n'"a860e8c0b6d573d191e4ec7db1b1e4f6 bios/gba_bios.bin"$'\n'
  out=$(python3 "${SCRIPTS}/rocknix-systems" --noFilter) || fail "--noFilter failed"
  assert_eq "$(echo "${out}" | grep -c '^> ')" "$(echo "${readme}" | grep -c ':$')" "systems listed without a filter"
  assert_contains "${out}" "> xbox"$'\n'"MISSING d49c52a4102f6df7bcf8d0617ac475ed bios/xemu/bios/mcpx_1.0.bin"
}

test_systems_parses_shipped_es_systems() {
  local out
  grep -q '<name>gba</name>' /usr/config/emulationstation/es_systems.cfg || skip "no gba system in this image"
  systems_setup
  cp /usr/config/emulationstation/es_systems.cfg /storage/.config/emulationstation/es_systems.cfg
  out=$(python3 "${SCRIPTS}/rocknix-systems" 2>&1) || fail "rocknix-systems failed on the shipped es_systems.cfg: ${out}"
  assert_contains "${out}" "> gba"$'\n'"UNTESTED a860e8c0b6d573d191e4ec7db1b1e4f6 bios/gba_bios.bin"
}
