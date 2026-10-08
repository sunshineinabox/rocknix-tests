# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

FUNCTIONS=${REPO}/projects/ROCKNIX/packages/rocknix/profile.d/001-functions
SCRIPTS=${REPO}/projects/ROCKNIX/packages/rocknix/sources/scripts
CFG_DIR=/storage/.config/system/configs
CFG=${CFG_DIR}/system.cfg
DEFAULT_CFG=/usr/config/system/configs/system.cfg

wipe_storage() {
  rm -rf /storage/* /storage/.[!.]* /storage/..?* /tmp/.system.cfg.lock
}

settings_fixture() {
  wipe_storage
  mkdir -p "${CFG_DIR}"
  : >"${CFG}"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"${CFG}"
  trap wipe_storage EXIT
}

test_get_setting_precedence() {
  settings_fixture 'global.ratio=core' 'ratio=bare' 'system.ratio=sys' 'snes.ratio=16/9' \
    'snes["Super Mario World (USA).sfc"].ratio=4/3'
  . "${FUNCTIONS}"
  assert_eq "$(get_setting ratio snes 'Super Mario World (USA).sfc')" "4/3" "per-game key"
  assert_eq "$(get_setting ratio snes 'Other Game.sfc')" "16/9" "platform key"
  assert_eq "$(get_setting ratio snes)" "16/9" "platform key without a game"
  assert_eq "$(get_setting ratio nes 'Other Game.nes')" "sys" "system. key"
  sed -i '/^system.ratio=/d' "${CFG}"
  assert_eq "$(get_setting ratio nes)" "bare" "bare key"
  sed -i '/^ratio=/d' "${CFG}"
  assert_eq "$(get_setting ratio nes)" "core" "global. key"
  assert_eq "$(get_setting missing.key snes 'Other Game.sfc')" "" "missing key"
  rm -f "${CFG}"
  assert_eq "$(get_setting ratio snes 2>/dev/null)" "" "missing system.cfg"
}

test_get_setting_empty_value_falls_through() {
  settings_fixture 'snes["Game.sfc"].ratio=' 'snes.ratio=16/9' 'global.ratio=core' 'nes.ratio=' 'empty.key='
  . "${FUNCTIONS}"
  assert_eq "$(get_setting ratio snes 'Game.sfc')" "16/9" "empty per-game value"
  assert_eq "$(get_setting ratio nes)" "core" "empty platform value"
  assert_eq "$(get_setting empty.key)" "" "empty value with no fallback"
}

test_get_setting_matches_whole_keys() {
  settings_fixture 'xaudio.volume=1' 'audioXvolume=2' 'audio.volume.max=3' 'audio.volume=60' 'audio.volume=99'
  . "${FUNCTIONS}"
  assert_eq "$(get_setting audio.volume)" "60" "first exact match"
  assert_eq "$(get_setting audio.volume.max)" "3" "longer key"
}

test_set_setting_special_characters() {
  settings_fixture
  . "${FUNCTIONS}"
  set_setting wifi.ssid 'My Home Net'
  set_setting test.equals 'a=b=c'
  set_setting test.quotes "it's \"quoted\""
  set_setting test.path '/storage/roms/bios/scph 1001.bin'
  set_setting test.backslash 'C:\games\psx'
  assert_eq "$(get_setting wifi.ssid)" "My Home Net" "spaces"
  assert_eq "$(get_setting test.equals)" "a=b=c" "equals signs"
  assert_eq "$(get_setting test.quotes)" "it's \"quoted\"" "quotes"
  assert_eq "$(get_setting test.path)" "/storage/roms/bios/scph 1001.bin" "slashes"
  assert_eq "$(get_setting test.backslash)" 'C:\games\psx' "backslashes"
  assert_eq "$(grep -c '' "${CFG}")" "5" "one line per key"
}

test_get_setting_returns_value_verbatim() {
  settings_fixture
  . "${FUNCTIONS}"
  touch a b
  set_setting wifi.ssid 'My  Net '
  set_setting wifi.key '*'
  assert_eq "$(grep '^wifi' "${CFG}")" $'wifi.ssid=My  Net \nwifi.key=*' "stored as given"
  assert_eq "$(get_setting wifi.ssid)" "My  Net " "repeated and trailing spaces"
  assert_eq "$(get_setting wifi.key)" "*" "glob characters"
}

test_set_setting_overwrite_default_and_invalid_keys() {
  local before
  settings_fixture
  rm -f "${CFG}"
  . "${FUNCTIONS}"
  set_setting test.key 1
  assert_eq "$(cat "${CFG}")" "$(cat "${DEFAULT_CFG}"; echo test.key=1)" "seeded from defaults"
  set_setting audio.volume 80
  set_setting audio.volume 85
  assert_eq "$(grep '^audio.volume=' "${CFG}")" "audio.volume=85" "overwrite"
  set_setting global.test.empty fallback
  set_setting test.empty ""
  assert_eq "$(grep '^test.empty' "${CFG}")" "test.empty=" "empty value is stored"
  assert_eq "$(get_setting test.empty)" "fallback" "empty value falls through"
  set_setting test.key default
  grep -q '^test.key' "${CFG}" && fail "default did not remove the key"
  before=$(cat "${CFG}")
  set_setting '#comment' 1
  set_setting '-x' 1
  set_setting '' 1
  set_setting ' lead' 1
  assert_eq "$(cat "${CFG}")" "${before}" "invalid keys are ignored"
}

test_del_setting_removes_only_that_key() {
  settings_fixture 'led.color=red' 'led.colorful=1' 'xled.color=2' 'led.brightness=5' 'led.color=blue'
  . "${FUNCTIONS}"
  del_setting led.color
  assert_eq "$(cat "${CFG}")" $'led.colorful=1\nxled.color=2\nled.brightness=5' "remaining keys"
  del_setting '.*'
  del_setting ''
  assert_eq "$(grep -c '' "${CFG}")" "3" "keys not starting alphanumeric are ignored"
}

test_per_game_setting_overwrite_and_delete() {
  local key='snes["Super Mario World (USA).sfc"].ratio'
  settings_fixture 'snes.ratio=16/9' "${key}=4/3"
  . "${FUNCTIONS}"
  set_setting "${key}" full
  assert_eq "$(get_setting ratio snes 'Super Mario World (USA).sfc')" "full" "overwritten per-game value"
  assert_eq "$(grep -cF "${key}=" "${CFG}")" "1" "one line for the per-game key"
  del_setting "${key}"
  assert_eq "$(get_setting ratio snes 'Super Mario World (USA).sfc')" "16/9" "deleted per-game value"
}

test_sort_settings_orders_without_losing_settings() {
  local want extra=('snes["Game (USA).sfc"].ratio=4/3' 'zzz.last=1' '3do.first=1' 'wifi.ssid=My Net' 'audio.volume=61')
  settings_fixture
  export LC_ALL=C
  { echo '# comment'; cat "${DEFAULT_CFG}"; echo; printf '%s\n' "${extra[@]}"; } >"${CFG}"
  want=$({ cat "${DEFAULT_CFG}"; printf '%s\n' "${extra[@]}"; } | sort)
  . "${FUNCTIONS}"
  sort_settings
  assert_eq "$(cat "${CFG}")" "${want}" "sorted settings"
  [ ! -e "${CFG}.tmp" ] || fail "temporary file left behind"
}

test_sort_settings_leaves_config_without_settings_alone() {
  settings_fixture '# only a comment'
  . "${FUNCTIONS}"
  sort_settings 2>/dev/null
  assert_eq "$(cat "${CFG}")" "# only a comment" "file without settings"
  rm -f "${CFG}"
  sort_settings 2>/dev/null
  [ ! -e "${CFG}" ] || fail "sort_settings created an empty system.cfg in place of a missing one"
}

test_sort_settings_keeps_keys_set_setting_accepts() {
  settings_fixture 'audio.volume=60'
  . "${FUNCTIONS}"
  set_setting Kodi.enabled 1
  assert_eq "$(get_setting Kodi.enabled)" "1" "stored by set_setting"
  sort_settings
  assert_eq "$(get_setting Kodi.enabled)" "1" "kept by sort_settings"
}

test_set_setting_concurrent_writers() {
  local i
  settings_fixture
  cp "${DEFAULT_CFG}" "${CFG}"
  . "${FUNCTIONS}"
  for i in $(seq 1 40); do
    (set_setting "test.key${i}" "first ${i}"; set_setting "test.key${i}" "second ${i}") &
  done
  wait
  for i in $(seq 1 40); do
    assert_eq "$(grep "^test.key${i}=" "${CFG}")" "test.key${i}=second ${i}" "test.key${i}"
  done
  assert_eq "$(grep -vc '^test.key' "${CFG}")" "$(grep -c '' "${DEFAULT_CFG}")" "default lines"
  assert_eq "$(grep -v '^test.key' "${CFG}")" "$(cat "${DEFAULT_CFG}")" "defaults unchanged"
}

test_set_setting_waits_for_lock() {
  local holder setter n=0
  settings_fixture 'audio.volume=60'
  mkfifo release
  bash -c ". '${FUNCTIONS}'; wait_lock; touch held; read -r _ <release; release_lock" &
  holder=$!
  while [ ! -e held ] && [ ${n} -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  [ -e held ] || fail "wait_lock did not return"
  bash -c ". '${FUNCTIONS}'; set_setting test.locked 1" &
  setter=$!
  sleep 0.5
  grep -q '^test.locked=' "${CFG}" && fail "set_setting wrote while the lock was held"
  echo >release
  wait ${holder} ${setter}
  assert_eq "$(grep '^test.locked=' "${CFG}")" "test.locked=1" "written after release"
  bash -c ". '${FUNCTIONS}'; wait_lock; kill -9 \$\$"
  timeout 5 bash -c ". '${FUNCTIONS}'; set_setting test.after 2" || fail "lock kept after its holder died"
  assert_eq "$(grep '^test.after=' "${CFG}")" "test.after=2" "written after holder died"
}

test_get_es_setting_types() {
  settings_fixture
  mkdir -p /storage/.config/emulationstation
  ln -s /storage/.config/emulationstation /storage/.emulationstation
  cat >/storage/.config/emulationstation/es_settings.cfg <<'EOF'
<?xml version="1.0"?>
<config>
	<bool name="DrawFramerate" value="false" />
	<int name="MaxVRAM" value="150" />
	<string name="ThemeSet" value="es-theme-art-book-next" />
	<string name="Theme" value="dark" />
	<string name="ScreenSaverBehavior" value="slide show" />
	<float name="GameTransitionTime" value="0.5" />
</config>
EOF
  . "${FUNCTIONS}"
  assert_eq "$(get_es_setting bool DrawFramerate)" "false" "bool"
  assert_eq "$(get_es_setting int MaxVRAM)" "150" "int"
  assert_eq "$(get_es_setting string ThemeSet)" "es-theme-art-book-next" "string"
  assert_eq "$(get_es_setting string Theme)" "dark" "name that prefixes another"
  assert_eq "$(get_es_setting string ScreenSaverBehavior)" "slide show" "string with a space"
  assert_eq "$(get_es_setting float GameTransitionTime)" "0.5" "float"
  assert_eq "$(get_es_setting string MaxVRAM)" "" "wrong type"
  assert_eq "$(get_es_setting string Missing)" "" "missing name"
}

test_rocknix_settings_load() {
  local out rc
  settings_fixture 'audio.volume=60' 'wifi.ssid=Old Net' 'empty.key=' '#kodi.enabled=1' 'system.language=fr_FR'
  out=$(bash "${SCRIPTS}/rocknix-settings" -command load -key audio.volume)
  assert_eq "$?:${out}" "0:60" "single-dash longform"
  out=$(bash "${SCRIPTS}/rocknix-settings" --command load --key wifi.ssid)
  assert_eq "$?:${out}" "0:Old Net" "double-dash longform"
  out=$(bash "${SCRIPTS}/rocknix-settings" get system.language)
  assert_eq "$?:${out}" "0:fr_FR" "shortform"
  bash "${SCRIPTS}/rocknix-settings" load empty.key >/dev/null 2>&1
  assert_eq "$?" "10" "empty value"
  bash "${SCRIPTS}/rocknix-settings" load kodi.enabled >/dev/null 2>&1
  assert_eq "$?" "11" "commented key"
  bash "${SCRIPTS}/rocknix-settings" load missing.key >/dev/null 2>&1
  assert_eq "$?" "12" "missing key"
  printf 'own.key=own value\n' >own.cfg
  out=$(bash "${SCRIPTS}/rocknix-settings" own.cfg load own.key)
  assert_eq "$?:${out}" "0:own value" "own config file"
  rm -f "${CFG}"
  bash "${SCRIPTS}/rocknix-settings" load audio.volume >/dev/null 2>&1
  assert_eq "$?" "2" "missing system.cfg"
}

test_rocknix_settings_write_enable_disable() {
  settings_fixture 'audio.volume=60' 'wifi.ssid=Old Net' '#kodi.enabled=1' 'wifi.enabled=0' \
    'system.security.enabled=1' 'audio.device=headphone'
  bash "${SCRIPTS}/rocknix-settings" -command write -key wifi.ssid -value "This is my NET" 2>/dev/null ||
    fail "write failed"
  bash "${SCRIPTS}/rocknix-settings" write missing.key 5 >/dev/null 2>&1
  assert_eq "$?" "12" "write of a missing key"
  bash "${SCRIPTS}/rocknix-settings" write kodi.enabled 0 2>/dev/null
  bash "${SCRIPTS}/rocknix-settings" enable wifi.enabled 2>/dev/null
  bash "${SCRIPTS}/rocknix-settings" disable system.security.enabled 2>/dev/null
  bash "${SCRIPTS}/rocknix-settings" disable audio.device 2>/dev/null
  assert_eq "$(cat "${CFG}")" "$(printf '%s\n' 'audio.volume=60' 'wifi.ssid=This is my NET' 'kodi.enabled=0' \
    'wifi.enabled=1' 'system.security.enabled=0' '#audio.device=headphone')" "config after edits"
  bash "${SCRIPTS}/rocknix-settings" enable audio.device 2>/dev/null
  assert_eq "$(grep 'audio.device' "${CFG}")" "audio.device=headphone" "enable uncomments"
}

test_rocknix_settings_write_value_with_slash() {
  settings_fixture 'gba.ratio=core' 'audio.volume=60'
  bash "${SCRIPTS}/rocknix-settings" write gba.ratio 3/2 >/dev/null 2>&1
  local rc=$?
  assert_eq "$(bash "${SCRIPTS}/rocknix-settings" load gba.ratio)" "3/2" "written value (write exited ${rc})"
}

test_chksysconfig_backup_and_restore() {
  settings_fixture
  mkdir -p /storage/.config/retroarch
  cp /usr/config/retroarch/retroarch.cfg /usr/config/retroarch/retroarch-core-options.cfg /storage/.config/retroarch/
  { cat "${DEFAULT_CFG}"; echo user.key=1; } >"${CFG}"
  bash "${SCRIPTS}/chksysconfig" backup >/dev/null 2>&1
  cmp -s "${CFG}" "${CFG}.backup" || fail "backup did not copy system.cfg"
  echo user.key=2 >>"${CFG}"
  bash "${SCRIPTS}/chksysconfig" restore >/dev/null 2>&1
  cmp -s "${CFG}" "${CFG}.backup" || fail "restore did not copy the backup back"
  printf 'audio.volume=60\0\0\0\0' >"${CFG}"
  bash "${SCRIPTS}/chksysconfig" backup >/dev/null 2>&1
  assert_eq "$(grep -c '^user.key=1$' "${CFG}.backup")" "1" "backup skipped for a binary system.cfg"
  bash "${SCRIPTS}/chksysconfig" verify >/dev/null 2>&1
  cmp -s "${CFG}" "${CFG}.backup" || fail "verify did not restore a binary system.cfg"
}

test_chksysconfig_handles_nul_filled_config() {
  settings_fixture
  mkdir -p /storage/.config/retroarch
  cp /usr/config/retroarch/retroarch.cfg /usr/config/retroarch/retroarch-core-options.cfg /storage/.config/retroarch/
  { cat "${DEFAULT_CFG}"; echo user.key=1; } >"${CFG}.backup"
  head -c 4096 /dev/zero >"${CFG}"
  bash "${SCRIPTS}/chksysconfig" backup >/dev/null 2>&1
  assert_eq "$(grep -c '^user.key=1$' "${CFG}.backup")" "1" "backup kept over a NUL-filled system.cfg"
  head -c 4096 /dev/zero >"${CFG}"
  bash "${SCRIPTS}/chksysconfig" verify >/dev/null 2>&1
  assert_eq "$(grep -c '^user.key=1$' "${CFG}")" "1" "verify restored the backup"
}

test_chksysconfig_verify_restores_missing_defaults() {
  local before
  settings_fixture
  cp -a /usr/config/. /storage/.config/
  mkdir -p /storage/.config/profile.d
  echo user.key=1 >>"${CFG}"
  before=$(cd /storage && find . -exec stat -c '%N %s %Y' {} + | sort)
  bash "${SCRIPTS}/chksysconfig" verify >/dev/null 2>&1
  assert_eq "$(cd /storage && find . -exec stat -c '%N %s %Y' {} + | sort)" "${before}" "healthy storage changed"
  rm -f /storage/.config/retroarch/retroarch.cfg
  bash "${SCRIPTS}/chksysconfig" verify >/dev/null 2>&1
  cmp -s /storage/.config/retroarch/retroarch.cfg /usr/config/retroarch/retroarch.cfg ||
    fail "missing retroarch.cfg not restored"
}
