# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

ROCKNIX=${REPO}/projects/ROCKNIX
PACKAGES=${ROCKNIX}/packages
QUIRKS=${PACKAGES}/hardware/quirks
INSTALLED=/usr/lib/autostart/quirks
CFG=/storage/.config/system/configs/system.cfg
SHELL_ERRORS='command not found|syntax error|unexpected (token|end of file|EOF)|operator expected|integer expression expected|bad substitution|ambiguous redirect|too many arguments|bad array subscript'
SLEEP_TOOLS="/usr/bin/systemctl /usr/bin/rocknix-games-freeze /usr/bin/wifictl /usr/bin/modprobe /usr/bin/amixer
  /usr/bin/brightness /usr/bin/ledcontrol /usr/sbin/quantum /usr/bin/pactl"
BOOT_TOOLS="/usr/bin/systemctl /usr/bin/modprobe /usr/bin/amixer /usr/bin/pactl"

hw_device() {
  (
    . /etc/os-release
    echo "${HW_DEVICE}"
  )
}

settings() {
  rm -rf /storage/.config
  mkdir -p "${CFG%/*}" /storage/.config/profile.d
  printf '%s\n' "$@" >"${CFG}"
}

log_tools() {
  local t
  for t in "$@"; do
    stub "${t}" <<'EOF'
#!/bin/sh
echo "${0##*/}${*:+ $*}" >>/tmp/quirks.log
EOF
  done
}

use_repo_quirks() {
  mv "${INSTALLED}" /.quirks.orig || fail "cannot move ${INSTALLED} aside"
  mkdir -p "${INSTALLED}/platforms" "${INSTALLED}/devices"
  cp -a "${QUIRKS}/devices/." "${INSTALLED}/devices/"
  cp -a "${QUIRKS}/platforms/." "${INSTALLED}/platforms/"
  chmod -R 0755 "${INSTALLED}"
}

restore_quirks() {
  [ -d /.quirks.orig ] || return 0
  rm -rf "${INSTALLED}"
  mv /.quirks.orig "${INSTALLED}"
}

in_order() {
  local file=$1 want i=0
  local -a lines
  mapfile -t lines <"${file}"
  shift
  for want in "$@"; do
    while [ ${i} -lt ${#lines[@]} ] && [ "${lines[${i}]}" != "${want}" ]; do i=$((i + 1)); done
    [ ${i} -lt ${#lines[@]} ] || fail "[${want}] missing or out of order in:"$'\n'"$(cat "${file}")"
    i=$((i + 1))
  done
}

shell_errors() {
  grep -E "${SHELL_ERRORS}" "$@"
}

test_quirk_and_sleep_scripts_parse() {
  local f sh out errors="" n=0
  while IFS= read -r -d '' f; do
    case "$(head -n 1 "${f}")" in
      '#!'*bash*) sh=bash ;;
      '#!'*/sh | '#!'*'/sh '*) sh=/bin/sh ;;
      '#!'*) continue ;;
      *)
        case "${f#"${QUIRKS}"/}" in
          platforms/*/*/* | devices/*/*/*) continue ;;
          platforms/*/* | devices/*/*) sh=bash ;;
          *) continue ;;
        esac
        ;;
    esac
    n=$((n + 1))
    out=$(${sh} -n "${f}" 2>&1) || errors="${errors}${out:-${f}: parse failed}"$'\n'
  done < <(
    find "${QUIRKS}" -type f ! -path '*/system.d/*' ! -name package.mk -print0
    find "${ROCKNIX}" \( -path '*/system-sleep/*' -o -path '*/sleep.d*/*' \) -type f ! -path "${QUIRKS}/*" -print0
    printf '%s\0' "${PACKAGES}/sysutils/sleep/sources/sleep.sh"
  )
  [ ${n} -gt 100 ] || fail "only ${n} scripts found"
  [ -z "${errors}" ] || fail "scripts that do not parse:"$'\n'"${errors%$'\n'}"
}

test_sleep_hook_suspend_and_resume() {
  local hw hook p m removed="" kept="" pre post
  hw=$(hw_device)
  trap 'restore_quirks; unstub ${SLEEP_TOOLS} /usr/bin/lsmod /usr/config/modules.bad; rm -rf /storage/.config /tmp/quirks.log /tmp/modules.load /var/log/sleep.log /run/.last_sleep_time' EXIT
  hook=${ROCKNIX}/devices/${hw}/filesystem/usr/lib/systemd/system-sleep/sleep
  [ -e "${hook}" ] || hook=${PACKAGES}/sysutils/sleep/sources/sleep.sh
  use_repo_quirks
  for p in pre post; do
    mkdir -p "${INSTALLED}/platforms/${hw}/sleep.d/${p}"
    printf '#!/bin/sh\necho "quirk %s" >>/tmp/quirks.log\n' "${p}" >"${INSTALLED}/platforms/${hw}/sleep.d/${p}/zzz-test"
    chmod 0755 "${INSTALLED}/platforms/${hw}/sleep.d/${p}/zzz-test"
  done
  log_tools ${SLEEP_TOOLS}
  stub /usr/config/modules.bad <"${PACKAGES}/sysutils/sleep/sources/modules.bad"
  stub /usr/bin/lsmod <<'EOF'
#!/bin/sh
echo "Module                  Size  Used by"
for m in $(cat /usr/config/modules.bad); do echo "${m} 16384 0"; done
EOF
  for m in $(cat "${PACKAGES}/sysutils/sleep/sources/modules.bad"); do
    if grep -qw -- "${m}" "${QUIRKS}/platforms/${hw}/modules.keep" 2>/dev/null; then
      kept="${kept} ${m}"
    else
      removed="${removed} ${m}"
    fi
  done
  settings wifi.enabled=1 controllers.bluetooth.enabled=1 audio.volume=60 display.brightness=40 display.brightness2=70 led.color=red
  printf '%s\n' 'DEVICE_FAKE_JACKSENSE="true"' 'DEVICE_AUDIO_MIXER="Master"' >/storage/.config/profile.d/001-test
  rm -f /tmp/quirks.log /tmp/modules.load
  mkdir -p /var/log
  ln -sf /proc/self/fd/2 /var/log/sleep.log
  bash "${hook}" pre 2>&1 </dev/null | cat >pre.out
  assert_eq "${PIPESTATUS[0]}" "0" "sleep hook pre exit status"
  mv /tmp/quirks.log pre.log
  bash "${hook}" post 2>&1 </dev/null | cat >post.out
  assert_eq "${PIPESTATUS[0]}" "0" "sleep hook post exit status"
  mv /tmp/quirks.log post.log
  pre=$(shell_errors pre.out)
  post=$(shell_errors post.out)
  [ -z "${pre}${post}" ] || fail "shell errors:"$'\n'"${pre}"$'\n'"${post}"
  in_order pre.log "rocknix-games-freeze freeze" "wifictl pin" "wifictl disable" "systemctl stop headphones" \
    "systemctl stop input" "systemctl stop bluetooth" "systemctl stop powerstate"
  for m in ${removed}; do in_order pre.log "systemctl stop powerstate" "modprobe -r ${m}" "quirk pre"; done
  for m in ${kept}; do grep -qxF "modprobe -r ${m}" pre.log && fail "${m} unloaded despite modules.keep"; done
  [ -e /run/.last_sleep_time ] || fail "no /run/.last_sleep_time after pre"
  in_order post.log "ledcontrol" "systemctl start powerstate" "systemctl start headphones" "systemctl start input" \
    "systemctl start bluetooth" "wifictl enable" "amixer -c 0 -M set Master 60%" "brightness set 40" \
    "brightness set 2 70" "quirk post" "rocknix-games-freeze thaw"
  for m in ${removed}; do in_order post.log "ledcontrol" "modprobe ${m}" "systemctl start powerstate"; done
  [ -e /tmp/modules.load ] && fail "/tmp/modules.load left after post"
  return 0
}

boot() {
  bash -a -c '
    source /etc/profile >/dev/null 2>&1
    for script in "$@"; do
      [ -f "${script}" ] || continue
      timeout 30 "${script}" 2>&1 >/dev/null </dev/null | sed "s|^|${script##*/}: |"
    done' autostart "${INSTALLED}/platforms/$(hw_device)"/* common/* >"$1" 2>&1
}

autostart_setup() {
  trap 'restore_quirks; unstub ${BOOT_TOOLS}; rm -rf /storage/.config /storage/.quirk-platform-configs /tmp/quirks.log' EXIT
  [ -d "${QUIRKS}/platforms/$(hw_device)" ] || skip "no platform quirks for $(hw_device)"
  use_repo_quirks
  mkdir -p common
  cp -a "${QUIRKS}/autostart/." common/
  chmod 0755 common/*
  log_tools ${BOOT_TOOLS}
  settings
  cp -a /usr/config/system /usr/config/sleep.conf.d /storage/.config/ 2>/dev/null
}

test_autostart_quirks_first_boot() {
  local errors
  autostart_setup
  boot first.out
  errors=$(shell_errors first.out)
  [ -z "${errors}" ] || fail "shell errors on first boot:"$'\n'"${errors}"
}

test_autostart_quirks_second_boot() {
  local errors
  autostart_setup
  boot first.out
  boot second.out
  errors=$(shell_errors second.out)
  [ -z "${errors}" ] || fail "shell errors on a later boot:"$'\n'"${errors}"
}
