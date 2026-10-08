# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PACKAGES=${REPO}/projects/ROCKNIX/packages
AUTOSTART=${PACKAGES}/rocknix/autostart
PROFILED=${PACKAGES}/rocknix/profile.d
SCRIPTS=${PACKAGES}/rocknix/sources/scripts
DAEMONS=/usr/lib/autostart/daemons
CFG=/storage/.config/system/configs/system.cfg
LOG=/tmp/autostart.log
GOVERNORS=/sys/devices/system/cpu/cpufreq/policy0/scaling_available_governors
TOOLS="/usr/bin/systemctl /usr/bin/brightness /usr/bin/suspendmode /usr/bin/setrootpass /usr/bin/wifictl
  /usr/bin/usbgadget /usr/bin/chksysconfig /usr/share/post-update"
SERVICES="ssh.enabled:sshd samba.enabled:nmbd,smbd syncthing.enabled:syncthing tailscale.up:tailscaled
  zerotier.up:zerotier-one fstrim.enabled:fstrim.timer"

wipe_storage() {
  rm -rf /storage/* /storage/.[!.]* /storage/..?* /tmp/.system.cfg.lock
}

settings() {
  wipe_storage
  mkdir -p "${CFG%/*}"
  printf '%s\n' "$@" >"${CFG}"
}

setting() {
  sed -n "s/^$1=//p" "${CFG}"
}

log_tools() {
  local t
  for t in "$@"; do
    stub "${t}" <<'EOF'
#!/bin/sh
l=${0##*/}
for a in "$@"; do l="${l} [${a}]"; done
echo "${l}" >>/tmp/autostart.log
EOF
  done
}

calls() {
  if [ -n "$1" ]; then grep "^$1 " "${LOG}" 2>/dev/null; else cat "${LOG}" 2>/dev/null; fi
}

teardown() {
  unstub /etc/profile.d/001-functions /etc/profile.d/099-freqfunctions ${TOOLS} /usr/bin/awk /usr/bin/emulationstation \
    /usr/share/weston/weston.ini /usr/share/weston/kiosk.ini /usr/config/ssh/authorized_keys
  rmdir /usr/share/weston /usr/config/ssh 2>/dev/null
  if [ -d /.daemons.orig ]; then
    rm -rf "${DAEMONS}"
    [ -d /.daemons.orig/daemons ] && mv /.daemons.orig/daemons "${DAEMONS}"
    rm -rf /.daemons.orig
  fi
  [ -z "${RUNTIME_DIR_CREATED}" ] || rm -rf /var/run/0-runtime-dir
  rm -rf /run/samba /tmp/cache /tmp/governors /var/log/upgrade.log "${LOG}"
  wipe_storage
}

autostart_fixture() {
  trap teardown EXIT
  settings "$@"
  stub /etc/profile.d/001-functions <"${PROFILED}/001-functions"
  log_tools ${TOOLS}
  mkdir -p /var/log
  rm -f "${LOG}"
}

run_step() {
  local step=$1
  shift
  sh "${AUTOSTART}/${step}" "$@" 2>&1 >/dev/null </dev/null | cat >"${step}.err"
  [ ! -s "${step}.err" ] || fail "${step} wrote to stderr:"$'\n'"$(cat "${step}.err")"
}

freq_functions() {
  {
    echo ". ${PROFILED}/099-freqfunctions"
    cat <<'EOF'
declare -F onlinethreads gpu_performance_level >/dev/null || echo "099-freqfunctions lacks onlinethreads or gpu_performance_level" >&2
log_call() {
  local l=$1
  shift
  for a in "$@"; do l="${l} [${a}]"; done
  echo "${l}" >>/tmp/autostart.log
}
onlinethreads() { log_call onlinethreads "$@"; }
gpu_performance_level() { log_call gpu_performance_level "$@"; }
EOF
  } | stub /etc/profile.d/099-freqfunctions
}

fake_governors() {
  local real
  echo "$1" >/tmp/governors
  real=$(readlink -f /usr/bin/awk)
  case "${real}" in
    */busybox) real="${real} awk" ;;
    /usr/bin/awk) real=/.stubs/orig/usr/bin/awk ;;
  esac
  stub /usr/bin/awk <<EOF
#!/bin/bash
args=()
for a in "\$@"; do
  [ "\${a}" = ${GOVERNORS} ] && a=/tmp/governors
  args+=("\${a}")
done
exec ${real} "\${args[@]}"
EOF
}

weston_configs() {
  printf '[shell]\nmode=desktop\n[autolaunch]\npath=@STARTUP@\n' | stub /usr/share/weston/weston.ini
  printf '[shell]\nmode=kiosk\n[autolaunch]\npath=@STARTUP@\n' | stub /usr/share/weston/kiosk.ini
}

emulationstation_binary() {
  stub /usr/bin/emulationstation </dev/null
  [ "$1" = present ] || rm -f /usr/bin/emulationstation
}

use_repo_daemons() {
  mkdir -p /.daemons.orig
  [ -d "${DAEMONS}" ] && mv "${DAEMONS}" /.daemons.orig/
  mkdir -p "${DAEMONS}"
  find "${PACKAGES}" -path '*/daemons/*' -type f -exec cp {} "${DAEMONS}/" \;
}

run_services() {
  settings "$@"
  boot_services
}

boot_services() {
  rm -rf /run/samba "${LOG}"
  run_step 099-networkservices
}

expect_services() {
  local action=$1 units=$2 context=$3 u
  for u in ${units//,/ }; do
    assert_eq "$(grep -c "^systemctl \[[a-z]*\] \[${u}\]$" "${LOG}")" "1" "${context}: one systemctl call for ${u}"
    grep -qxF "systemctl [${action}] [${u}]" "${LOG}" ||
      fail "${context}: no systemctl ${action} ${u}:"$'\n'"$(sort "${LOG}")"
  done
}

test_setup_prepares_storage() {
  autostart_fixture 'b.key=2' 'a.key=1'
  [ -d /var/run/0-runtime-dir ] || RUNTIME_DIR_CREATED=1
  mkdir -p /storage/cache/.cores
  touch /storage/cache/.cores/stale
  run_step 001-setup
  assert_eq "$(calls)" "chksysconfig [verify]" "system.cfg verified"
  assert_eq "$(cat "${CFG}")" $'a.key=1\nb.key=2' "settings sorted"
  assert_eq "$(readlink /storage/cache/.cores)" "/tmp/cache" "core cache link"
  [ -d /tmp/cache ] || fail "no /tmp/cache"
  [ -d /storage/.config/profile.d ] || fail "no /storage/.config/profile.d"
  assert_eq "$(stat -c %a /var/run/0-runtime-dir)" "700" "runtime dir mode"
}

test_setup_on_fresh_storage() {
  autostart_fixture 'a.key=1'
  [ -d /var/run/0-runtime-dir ] || RUNTIME_DIR_CREATED=1
  run_step 001-setup
}

test_upgrade_runs_post_update_once() {
  autostart_fixture
  stub /usr/share/post-update <<'EOF'
#!/bin/sh
echo "post-update ran"
echo post-update >>/tmp/autostart.log
EOF
  echo UPDATE >/storage/.boot.hint
  run_step 003-upgrade
  assert_eq "$(calls)" "post-update" "post-update with an update hint"
  assert_eq "$(cat /var/log/upgrade.log)" "post-update ran" "post-update output in upgrade.log"
  [ ! -e /storage/.boot.hint ] || fail "update hint kept"
  rm -f "${LOG}"
  run_step 003-upgrade
  assert_eq "$(calls)" "" "post-update without an update hint"
  assert_eq "$(cat /var/log/upgrade.log)" "No update hint found." "upgrade.log without an update hint"
}

test_display_restores_brightness() {
  local cfg want
  autostart_fixture
  while IFS='|' read -r cfg want; do
    settings ${cfg}
    rm -f "${LOG}"
    run_step 006-display
    assert_eq "$(calls)" "$(printf "${want}")" "[${cfg}]"
  done <<'EOF'
display.brightness=40|brightness [set] [40]
display.brightness=5|brightness [set] [5]
display.brightness=4|brightness [set] [10]
display.brightness=0|brightness [set] [10]
|brightness [set] [10]
display.brightness=40 display.brightness2=70|brightness [set] [40]\nbrightness [set] [2] [70]
display.brightness=40 display.brightness2=3|brightness [set] [40]\nbrightness [set] [2] [10]
display.brightness2=5|brightness [set] [10]\nbrightness [set] [2] [5]
EOF
}

test_rootpw_applies_saved_password() {
  autostart_fixture 'root.password=S3cret pass'
  run_step 007-rootpw
  assert_eq "$(calls)" "setrootpass [S3cret pass]" "root.password"
  [ -f /storage/.cache/samba/smbpasswd ] || fail "no samba password file"
  echo 'root:0:hash' >/storage/.cache/samba/smbpasswd
  run_step 007-rootpw
  assert_eq "$(cat /storage/.cache/samba/smbpasswd)" "root:0:hash" "existing samba passwords"
}

test_rootpw_without_setting_keeps_a_password() {
  autostart_fixture
  run_step 007-rootpw
  case "$(calls)" in
    *"setrootpass []"*) fail "root password set to an empty string when root.password is missing" ;;
  esac
  return 0
}

test_perfmode_threads() {
  local cfg want
  autostart_fixture
  freq_functions
  fake_governors "ondemand performance"
  while IFS='|' read -r cfg want; do
    settings system.cpugovernor=performance ${cfg}
    rm -f "${LOG}"
    run_step 008-perfmode
    assert_eq "$(calls onlinethreads)" "${want}" "[${cfg}]"
  done <<'EOF'
system.threads=2|onlinethreads [2] [0]
system.threads=all|onlinethreads [all] [0]
|onlinethreads [all] [1]
EOF
}

test_perfmode_default_cpu_governor() {
  local available cfg want
  autostart_fixture
  freq_functions
  while IFS='|' read -r available cfg want; do
    fake_governors "${available}"
    settings ${cfg}
    run_step 008-perfmode
    assert_eq "$(setting system.cpugovernor)" "${want}" "system.cpugovernor with [${cfg}] and governors [${available}]"
  done <<'EOF'
conservative ondemand userspace powersave performance schedutil||ondemand
performance schedutil||performance
ondemand performance|system.cpugovernor=schedutil|schedutil
EOF
}

test_perfmode_gpu_performance_level() {
  local cfg want
  autostart_fixture
  freq_functions
  fake_governors "ondemand performance"
  while IFS='|' read -r cfg want; do
    settings system.cpugovernor=performance ${cfg}
    rm -f "${LOG}"
    run_step 008-perfmode
    assert_eq "$(calls gpu_performance_level)" "${want}" "[${cfg}]"
  done <<'EOF'
system.gpuperf=auto|gpu_performance_level [auto]
system.gpuperf=performance|gpu_performance_level [performance]
|
EOF
}

test_sleepmode_applies_suspend_mode() {
  local cfg want
  autostart_fixture
  while IFS='|' read -r cfg want; do
    settings ${cfg}
    rm -f "${LOG}"
    run_step 009-sleepmode
    assert_eq "$(calls)" "${want}" "[${cfg}]"
  done <<'EOF'
system.suspendmode=freeze|suspendmode [freeze]
system.suspendmode=off|suspendmode [off]
|suspendmode [mem]
EOF
}

test_uimode_selects_weston_config() {
  local cfg want
  autostart_fixture
  weston_configs
  emulationstation_binary present
  while IFS='|' read -r cfg want; do
    settings weston.startup=/usr/bin/start_es.sh ${cfg}
    run_step 010-uimode
    assert_eq "$(tr '\n' ';' </storage/.config/weston.ini)" "${want}" "weston.ini with [${cfg}]"
  done <<'EOF'
desktop.enabled=0|[shell];mode=kiosk;[autolaunch];path=/usr/bin/start_es.sh;
desktop.enabled=1|[shell];mode=desktop;[autolaunch];path=/usr/bin/start_es.sh;
|[shell];mode=kiosk;[autolaunch];path=/usr/bin/start_es.sh;
EOF
}

test_uimode_startup_command() {
  autostart_fixture desktop.enabled=0
  weston_configs
  emulationstation_binary present
  run_step 010-uimode
  assert_eq "$(sed -n 's/^path=//p' /storage/.config/weston.ini)" "/usr/bin/start_es.sh" "default startup command"
  assert_eq "$(setting weston.startup)" "/usr/bin/start_es.sh" "default startup command saved"
  settings desktop.enabled=0 weston.startup=/usr/bin/foot
  run_step 010-uimode
  assert_eq "$(sed -n 's/^path=//p' /storage/.config/weston.ini)" "/usr/bin/foot" "weston.startup"
  assert_eq "$(setting weston.startup)" "/usr/bin/foot" "weston.startup kept"
}

test_uimode_without_emulationstation() {
  autostart_fixture desktop.enabled=0
  weston_configs
  emulationstation_binary absent
  run_step 010-uimode
  assert_eq "$(sed -n 's/^mode=//p' /storage/.config/weston.ini)" "desktop" "desktop shell without EmulationStation"
  assert_eq "$(grep -c '^path=$' /storage/.config/weston.ini)" "1" "no startup command"
  assert_eq "$(setting weston.startup)" "" "weston.startup not saved"
}

test_uimode_without_weston() {
  [ ! -e /usr/share/weston/weston.ini ] || skip "weston is in this image"
  autostart_fixture desktop.enabled=0 weston.startup=/usr/bin/start_es.sh
  run_step 010-uimode
  [ ! -e /storage/.config/weston.ini ] || fail "weston.ini written without weston"
}

test_network_applies_wifi_setting() {
  local args cfg want
  autostart_fixture
  while IFS='|' read -r args cfg want; do
    settings ${cfg}
    rm -f "${LOG}"
    run_step 080-network ${args}
    assert_eq "$(calls)" "${want}" "080-network ${args} with [${cfg}]"
  done <<'EOF'
|wifi.enabled=1|wifictl [enable]
|wifi.enabled=0|wifictl [disable]
||
disable|wifi.enabled=1|wifictl [disable]
enable||wifictl [enable]
EOF
}

test_usbgadget_restores_mode() {
  autostart_fixture
  run_step 081-usbgadget
  assert_eq "$(calls)" "usbgadget [--start]" "081-usbgadget"
  grep -qE '^[[:space:]]*"?--start"?\)' "${SCRIPTS}/usbgadget" || fail "usbgadget has no --start option"
}

test_networkservices_follow_settings() {
  local row key cfg other
  autostart_fixture
  use_repo_daemons
  for row in ${SERVICES}; do
    key=${row%%:*}
    cfg=""
    for other in ${SERVICES}; do
      [ "${other}" = "${row}" ] && cfg="${cfg} ${key}=1" || cfg="${cfg} ${other%%:*}=0"
    done
    run_services ${cfg}
    for other in ${SERVICES}; do
      if [ "${other}" = "${row}" ]; then
        expect_services start "${other#*:}" "${key}=1"
      else
        expect_services stop "${other#*:}" "${key}=1, ${other%%:*}=0"
      fi
    done
  done
}

test_networkservices_default_off() {
  local row
  autostart_fixture
  use_repo_daemons
  run_services
  for row in ${SERVICES}; do
    expect_services stop "${row#*:}" "without ${row%%:*}"
  done
  [ -d /storage/.cache/services ] || fail "no /storage/.cache/services"
}

test_networkservices_ssh_state_file() {
  autostart_fixture
  use_repo_daemons
  run_services ssh.enabled=1
  [ -e /storage/.cache/services/sshd.conf ] || fail "ssh.enabled=1: no sshd.conf for sshd.service"
  settings ssh.enabled=0
  mkdir -p /storage/.cache/services
  touch /storage/.cache/services/sshd.conf
  boot_services
  [ ! -e /storage/.cache/services/sshd.conf ] || fail "ssh.enabled=0: sshd.conf kept"
}

test_networkservices_samba_state_file() {
  autostart_fixture
  use_repo_daemons
  run_services ssh.enabled=0 samba.enabled=1 syncthing.enabled=0 tailscale.up=0 zerotier.up=0 fstrim.enabled=0
  [ -e /storage/.cache/services/smb.conf ] || fail "samba.enabled=1: no smb.conf"
  run_services ssh.enabled=0 samba.enabled=0 syncthing.enabled=1 tailscale.up=1 zerotier.up=1 fstrim.enabled=1
  [ ! -e /storage/.cache/services/smb.conf ] || fail "samba.enabled=0: smb.conf created"
}

test_networkservices_samba_runtime_config() {
  autostart_fixture
  use_repo_daemons
  run_services samba.enabled=1
  assert_eq "$(readlink /run/samba/smb.conf)" "/etc/samba/smb.conf" "/run/samba/smb.conf"
}

test_networkservices_seed_authorized_keys() {
  autostart_fixture
  use_repo_daemons
  echo 'ssh-ed25519 AAAA builder' | stub /usr/config/ssh/authorized_keys
  run_services ssh.enabled=1
  assert_eq "$(cat /storage/.ssh/authorized_keys 2>&1)" "ssh-ed25519 AAAA builder" "authorized_keys from /usr/config/ssh"
  mkdir -p /storage/.ssh
  echo 'ssh-ed25519 BBBB user' >/storage/.ssh/authorized_keys
  boot_services
  assert_eq "$(cat /storage/.ssh/authorized_keys)" "ssh-ed25519 BBBB user" "user authorized_keys"
}

test_networkservices_units_exist() {
  local f repo units u missing="" n=0
  trap 'rm -rf /run/samba /storage/.ssh' EXIT
  for f in "${DAEMONS}"/*; do
    [ -f "${f}" ] || continue
    repo=$(find "${PACKAGES}" -path "*/daemons/${f##*/}" -type f | head -n 1)
    [ -n "${repo}" ] || continue
    units=$(bash -c 'get_setting() { :; }; source "$1" >/dev/null 2>&1; echo "${DAEMONS[@]}"' _ "${repo}")
    [ -n "${units}" ] || missing="${missing}${repo#"${REPO}"/}: no DAEMONS"$'\n'
    for u in ${units}; do
      n=$((n + 1))
      [ -e "/usr/lib/systemd/system/${u}" ] || [ -e "/usr/lib/systemd/system/${u}.service" ] ||
        missing="${missing}${repo#"${REPO}"/}: ${u}"$'\n'
    done
  done
  [ ${n} -gt 0 ] || skip "no service fragments in ${DAEMONS}"
  [ -z "${missing}" ] || fail "units started by 099-networkservices that are not in the image:"$'\n'"${missing%$'\n'}"
}
