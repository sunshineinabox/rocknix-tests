# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PACKAGES=${REPO}/projects/ROCKNIX/packages

test_pactl_sink_id() {
  trap 'unstub /usr/bin/pactl' EXIT
  stub /usr/bin/pactl <<'EOF'
#!/bin/sh
case "$*" in
  "list sinks short")
    printf '55\talsa_output.platform-es8316-sound.HiFi\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED\n'
    printf '142\talsa_output.platform-hdmi-sound.stereo\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n'
    ;;
  set-default-sink*) echo "$*" >>/tmp/pactl.log ;;
esac
EOF
  rm -f /tmp/pactl.log
  sh "${PACKAGES}/hardware/quirks/devices/Anbernic RG552/sleep.d/post/001-audio" >/dev/null 2>&1
  assert_eq "$(head -n 1 /tmp/pactl.log)" "set-default-sink 55" "speaker sink"
}

test_hdmi_hotplug_finds_es_started_by_unit() {
  local es
  trap 'unstub /usr/bin/wlr-randr; kill ${es} 2>/dev/null' EXIT
  stub /usr/bin/wlr-randr <<'EOF'
#!/bin/sh
[ $# -eq 0 ] && printf 'HDMI-A-1 "TV"\n  Enabled: no\nDSI-1 "Panel"\n  Enabled: yes\n'
exit 0
EOF
  mkdir -p fake
  cp "$(readlink -f /usr/bin/python3)" fake/emulationstation
  (exec -a /usr/bin/emulationstation fake/emulationstation -c 'import time; time.sleep(30)' --log-path /var/log) &
  es=$!
  sleep 0.5
  echo connected >/run/hdmi-status.last
  sh "${PACKAGES}/rocknix/sources/scripts/handle-hdmi-hotplug" >/dev/null 2>&1
  sleep 0.5
  kill -0 ${es} 2>/dev/null && fail "handle-hdmi-hotplug did not see EmulationStation"
  return 0
}

test_foot_config() {
  local out
  command -v foot >/dev/null || skip "no foot in this image"
  out=$(XDG_RUNTIME_DIR=/tmp foot --check-config -c "${PACKAGES}/wayland/util/foot/config/foot.ini" 2>&1)
  local rc=$?
  out=$(echo "${out}" | grep -v 'not a UTF-8 locale')
  [ ${rc} -eq 0 ] && [ -z "${out}" ] || fail "foot rejected foot.ini (rc ${rc}):"$'\n'"${out}"
}

test_sgdisk_reads_disk_image() {
  command -v sgdisk >/dev/null || skip "no sgdisk in this image"
  python3 "${TESTS}/lib/mkgpt.py" disk.img 16 one:4
  sgdisk -p disk.img 2>&1 | grep -q 'one' || fail "sgdisk cannot read a GPT image:"$'\n'"$(sgdisk -p disk.img 2>&1)"
}
