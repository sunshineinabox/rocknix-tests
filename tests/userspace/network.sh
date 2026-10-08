# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)
# privileged

SCRIPTS=${REPO}/projects/ROCKNIX/packages/rocknix/sources/scripts
SYSCFG=/storage/.config/system/configs/system.cfg
BTCACHE=/storage/.cache/bluetooth/11:22:33:44:55:66
MACHINEID=/storage/.cache/systemd-machine-id

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

no_route() {
  ip route 2>/dev/null | grep -q default && skip "the container has a default route"
  return 0
}

wifi_teardown() {
  unstub /usr/bin/nmcli /usr/bin/iwctl /usr/sbin/iw /usr/sbin/rfkill /usr/bin/sleep
  ip link del wlan0 2>/dev/null
  rm -f "${SYSCFG}" /tmp/nmcli.* /tmp/iw.log /tmp/rfkill.log
}

wifi_setup() {
  ip link del wlan0 2>/dev/null
  ip link add wlan0 type dummy 2>/dev/null || skip "cannot create a wlan0 interface outside a privileged container"
  trap wifi_teardown EXIT
  rm -f /tmp/nmcli.* /tmp/iw.log /tmp/rfkill.log
  settings "$@"
  printf 'Home Net\n\nCafe\nHome Net\nMy "Quoted" AP\n' >/tmp/nmcli.scan
  printf 'Home Net:802-11-wireless\nNETPLAY_AP:802-11-wireless\nWired connection 1:802-3-ethernet\nlo:loopback\nCafe:802-11-wireless\n' >/tmp/nmcli.conns
  stub /usr/bin/nmcli <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '[%s]' "$a"; done; echo; } >>/tmp/nmcli.log
case "$*" in
  "-t -f SSID dev wifi list ifname wlan0"|"-t -f SSID device wifi list ifname wlan0") cat /tmp/nmcli.scan ;;
  "-t -f DEVICE,STATE dev status") printf 'wlan0:disconnected\nlo:unmanaged\n' ;;
  "-t -f NAME,TYPE connection show") cat /tmp/nmcli.conns ;;
  "-t -f GENERAL.CONNECTION device show wlan0") echo 'GENERAL.CONNECTION:Home Net' ;;
  *"connection up"*) [ -e /tmp/nmcli.up-fails ] && exit 10 ;;
  *"device wifi connect"*) [ -e /tmp/nmcli.connect-fails ] && exit 4 ;;
esac
exit 0
EOF
  stub /usr/bin/iwctl <<'EOF'
#!/bin/sh
[ "$1 $2" = "device list" ] && printf '  Name    Address            Powered  Adapter  Mode\n  wlan0   02:00:00:00:00:01  on       phy0     station\n'
exit 0
EOF
  argv_stub /usr/sbin/iw
  argv_stub /usr/sbin/rfkill
  stub /usr/bin/sleep <<'EOF'
#!/bin/sh
EOF
}

test_wifictl_requires_wireless_interface() {
  local out rc
  ip link show wlan0 >/dev/null 2>&1 && skip "a wlan0 interface already exists"
  out=$(bash "${SCRIPTS}/wifictl" list 2>&1)
  rc=$?
  assert_eq "${rc}" 1 "exit status"
  assert_contains "${out}" "No wireless interface"
}

test_wifictl_enable_disable() {
  wifi_setup
  bash "${SCRIPTS}/wifictl" enable || fail "enable failed"
  bash "${SCRIPTS}/wifictl" disable || fail "disable failed"
  assert_eq "$(cat /tmp/rfkill.log)" "[unblock][wifi]"$'\n'"[block][wifi]"
}

test_wifictl_list_parses_scan() {
  local out
  wifi_setup 'wifi.country=DE'
  out=$(bash "${SCRIPTS}/wifictl" list)
  assert_eq "${out}" "Cafe"$'\n'"Home Net"$'\n'"My \"Quoted\" AP" "deduplicated sorted SSIDs"
  assert_contains "$(cat /tmp/nmcli.log)" "[-w][15][dev][wifi][rescan][ifname][wlan0]"
  assert_eq "$(cat /tmp/iw.log)" "[reg][set][DE]" "regulatory domain from settings"
}

test_wifictl_connect_passes_credentials_verbatim() {
  local ssid="Bob's \"Home\"  WiFi" psk='p@ss w0rd $HOME `id` \n;&|*'
  wifi_setup 'wifi.adhoc.enabled=0'
  bash "${SCRIPTS}/wifictl" connect "${ssid}" "${psk}" "US" || fail "connect failed"
  local log
  log=$(cat /tmp/nmcli.log)
  assert_contains "${log}" "[connection][delete][id][NETPLAY_AP]"
  assert_contains "${log}" "[connection][delete][id][${ssid}]"$'\n'"[-w][90][device][wifi][connect][${ssid}][password][${psk}][ifname][wlan0]"$'\n'"[connection][modify][${ssid}][wifi-sec.psk-flags][0]"
  assert_eq "$(cat /tmp/iw.log)" "[reg][set][US]"
}

test_wifictl_connect_uses_saved_settings() {
  wifi_setup 'wifi.ssid=Home Net' 'wifi.key=secret key' 'wifi.country=GB'
  bash "${SCRIPTS}/wifictl" connect || fail "connect failed"
  assert_contains "$(cat /tmp/nmcli.log)" "[-w][90][device][wifi][connect][Home Net][password][secret key][ifname][wlan0]"
  assert_eq "$(cat /tmp/iw.log)" "[reg][set][GB]"
}

test_wifictl_connect_open_network() {
  local log
  wifi_setup
  bash "${SCRIPTS}/wifictl" connect "Cafe" "" "" || fail "connecting a known open network failed"
  log=$(cat /tmp/nmcli.log)
  assert_contains "${log}" "[-w][30][connection][up][id][Cafe][ifname][wlan0]"
  case "${log}" in *"device][wifi][connect"*) fail "created a new profile although the saved one came up" ;; esac
  rm -f /tmp/nmcli.log
  touch /tmp/nmcli.up-fails
  bash "${SCRIPTS}/wifictl" connect "Cafe" "" "" || fail "connecting a new open network failed"
  log=$(cat /tmp/nmcli.log)
  assert_contains "${log}" "[connection][delete][id][Cafe]"$'\n'"[-w][90][device][wifi][connect][Cafe][ifname][wlan0]"
}

test_wifictl_connect_failure_exit_status() {
  wifi_setup
  touch /tmp/nmcli.connect-fails
  bash "${SCRIPTS}/wifictl" connect "Home Net" "wrong password" "" &&
    fail "wifictl connect exited 0 although nmcli could not connect"
  return 0
}

test_wifictl_saved_networks() {
  local out
  wifi_setup
  out=$(bash "${SCRIPTS}/wifictl" list_saved)
  assert_eq "${out}" "Cafe"$'\n'"Home Net" "wireless profiles without NETPLAY_AP"
  bash "${SCRIPTS}/wifictl" forget_saved "Home Net" || fail "forget_saved failed"
  assert_contains "$(cat /tmp/nmcli.log)" "[connection][delete][id][Home Net]"
  bash "${SCRIPTS}/wifictl" connect_saved "Cafe" || fail "connect_saved failed"
  assert_contains "$(cat /tmp/nmcli.log)" "[connection][reload]"$'\n'"[-w][30][connection][up][id][Cafe][ifname][wlan0]"
  touch /tmp/nmcli.up-fails
  bash "${SCRIPTS}/wifictl" connect_saved "Cafe" && fail "connect_saved hid a failed activation"
  return 0
}

test_wifictl_pin_prioritises_active_connection() {
  local log
  wifi_setup
  bash "${SCRIPTS}/wifictl" pin || fail "pin failed"
  log=$(grep 'autoconnect-priority' /tmp/nmcli.log | sort)
  assert_eq "${log}" "[connection][modify][Cafe][connection.autoconnect-priority][0]"$'\n'"[connection][modify][Home Net][connection.autoconnect-priority][100]"$'\n'"[connection][modify][NETPLAY_AP][connection.autoconnect-priority][0]"
}

test_wifictl_disconnect() {
  wifi_setup
  bash "${SCRIPTS}/wifictl" disconnect || fail "disconnect failed"
  assert_contains "$(cat /tmp/nmcli.log)" "[device][disconnect][wlan0]"
}

test_wifictl_netplay_host_and_client() {
  wifi_setup 'wifi.adhoc.enabled=1' 'wifi.adhoc.id=1'
  bash "${SCRIPTS}/wifictl" connect "Home Net" "ignored" || fail "netplay host failed"
  assert_contains "$(cat /tmp/nmcli.log)" "[connection][add][type][wifi][ifname][wlan0][con-name][NETPLAY_AP][ssid][NETPLAY_AP][802-11-wireless.mode][ap][802-11-wireless.band][bg][802-11-wireless-security.key-mgmt][wpa-psk][802-11-wireless-security.psk][deadbeef][ipv4.method][manual][ipv4.addresses][192.168.80.1/24][ipv6.method][disabled]"$'\n'"[-w][30][connection][up][id][NETPLAY_AP]"
  rm -f /tmp/nmcli.log
  settings 'wifi.adhoc.enabled=1' 'wifi.adhoc.id=3'
  echo NETPLAY_AP >>/tmp/nmcli.scan
  bash "${SCRIPTS}/wifictl" connect || fail "netplay client failed"
  assert_contains "$(cat /tmp/nmcli.log)" "[ipv4.addresses][192.168.80.3/24][ipv6.method][disabled][connection.autoconnect][no]"
  assert_contains "$(cat /tmp/nmcli.log)" "[-w][20][connection][up][id][NETPLAY_AP]"
}

test_wifictl_channels() {
  local out
  wifi_setup
  stub /usr/sbin/iw <<'EOF'
#!/bin/sh
[ "$1" = list ] || exit 1
cat <<'LIST'
Wiphy phy0
	Band 1:
		Frequencies:
			* 2412.0 MHz [1] (20.0 dBm)
			* 2467.0 MHz [12] (disabled)
	Band 2:
		Frequencies:
			* 5180.0 MHz [36] (22.0 dBm)
			* 5260.0 MHz [52] (20.0 dBm) (radar detection)
			* 5745.0 MHz [149] (20.0 dBm) (no IR)
LIST
EOF
  out=$(bash "${SCRIPTS}/wifictl" channels)
  assert_eq "${out}" "1"$'\n'"36"
}

test_wifictl_usage() {
  local out rc
  wifi_setup
  out=$(bash "${SCRIPTS}/wifictl" bogus)
  rc=$?
  assert_eq "${rc}" 1 "exit status"
  assert_contains "${out}" "Usage:"
}

bt_teardown() {
  unstub /usr/bin/bluetoothctl /usr/bin/systemctl
  rm -rf /storage/.cache/bluetooth /storage/roms/backups /run/bt_* /tmp/bluetoothctl.log /tmp/systemctl.log /tmp/bt.*
  rm -f "${SYSCFG}"
}

bt_setup() {
  trap bt_teardown EXIT
  rm -rf /storage/.cache/bluetooth /storage/roms/backups /run/bt_* /tmp/bluetoothctl.log /tmp/bt.*
  mkdir -p "${BTCACHE}/cache"
  printf '[General]\nDiscoverable=false\n' >"${BTCACHE}/settings"
  stub /usr/bin/bluetoothctl <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '[%s]' "$a"; done; echo; } >>/tmp/bluetoothctl.log
[ $# -eq 0 ] && { sed 's/^/stdin: /' >>/tmp/bluetoothctl.log; exit 0; }
case "$2" in
  info)
    echo "Device $3 (public)"
    if grep -qx "$3" /tmp/bt.connected 2>/dev/null; then printf '\tConnected: yes\n'; else printf '\tConnected: no\n'; fi
    ;;
  connect|disconnect)
    [ -e /tmp/bt.fail ] && { echo "Failed to $2: org.bluez.Error.Failed"; exit 1; }
    echo "Successful"
    ;;
esac
exit 0
EOF
}

bt_device() {
  mkdir -p "${BTCACHE}/$1"
  printf '[General]\nName=%s\nClass=%s\nSupportedTechnologies=BR/EDR;\nTrusted=%s\nBlocked=false\n' "$2" "$3" "$4" >"${BTCACHE}/$1/info"
  printf '[General]\nName=%s\n' "$2" >"${BTCACHE}/cache/$1"
}

test_bluetooth_list_trusted_devices() {
  local out
  bt_setup
  bt_device AA:BB:CC:DD:EE:01 "Xbox Wireless Controller" 0x000508 true
  bt_device AA:BB:CC:DD:EE:02 "Untrusted Speaker" 0x240414 false
  bt_device AA:BB:CC:DD:EE:03 "JBL Flip 5" 0x240414 true
  echo AA:BB:CC:DD:EE:01 >/tmp/bt.connected
  out=$(sh "${SCRIPTS}/rocknix-bluetooth" list | sort)
  assert_eq "${out}" '<device id="AA:BB:CC:DD:EE:01" name="Xbox Wireless Controller" type="joystick" connected="yes" />
<device id="AA:BB:CC:DD:EE:03" name="JBL Flip 5" type="" connected="no" />'
}

test_bluetooth_save_restore() {
  bt_setup
  bt_device AA:BB:CC:DD:EE:01 "8BitDo Pro 2" 0x002508 true
  sh "${SCRIPTS}/rocknix-bluetooth" save >/dev/null || fail "save failed"
  tar tf /storage/roms/backups/bluetooth.tar | grep -qx "bluetooth/11:22:33:44:55:66/AA:BB:CC:DD:EE:01/info" ||
    fail "backup lacks the device: $(tar tf /storage/roms/backups/bluetooth.tar)"
  rm -rf /storage/.cache/bluetooth
  sh "${SCRIPTS}/rocknix-bluetooth" restore >/dev/null || fail "restore failed"
  grep -qx 'Name=8BitDo Pro 2' "${BTCACHE}/AA:BB:CC:DD:EE:01/info" || fail "device not restored"
}

test_bluetooth_remove_device() {
  bt_setup
  bt_device AA:BB:CC:DD:EE:01 "Xbox Wireless Controller" 0x000508 true
  bt_device AA:BB:CC:DD:EE:03 "JBL Flip 5" 0x240414 true
  sh "${SCRIPTS}/rocknix-bluetooth" remove AA:BB:CC:DD:EE:01 >/dev/null
  assert_contains "$(cat /tmp/bluetoothctl.log)" "stdin: untrust AA:BB:CC:DD:EE:01"$'\n'"stdin: remove AA:BB:CC:DD:EE:01"
  [ -e "${BTCACHE}/AA:BB:CC:DD:EE:01" ] || [ -e "${BTCACHE}/cache/AA:BB:CC:DD:EE:01" ] && fail "device files left in the cache"
  [ -e "${BTCACHE}/AA:BB:CC:DD:EE:03/info" ] || fail "removed the other device"
  tar tf /storage/roms/backups/bluetooth.tar | grep -q 'EE:01' && fail "backup still has the removed device"
  return 0
}

test_bluetooth_connect_disconnect() {
  local out
  bt_setup
  out=$(sh "${SCRIPTS}/rocknix-bluetooth" connect AA:BB:CC:DD:EE:01)
  assert_contains "${out}" "Successfully connected"
  assert_contains "$(cat /tmp/bluetoothctl.log)" "[--][connect][AA:BB:CC:DD:EE:01]"
  echo AA:BB:CC:DD:EE:01 >/tmp/bt.connected
  rm -f /tmp/bluetoothctl.log
  out=$(sh "${SCRIPTS}/rocknix-bluetooth" connect AA:BB:CC:DD:EE:01)
  assert_contains "${out}" "already connected"
  grep -q '\[connect\]' /tmp/bluetoothctl.log && fail "reconnected a connected device"
  out=$(sh "${SCRIPTS}/rocknix-bluetooth" disconnect AA:BB:CC:DD:EE:01)
  assert_contains "${out}" "Successfully disconnected"
  assert_contains "$(cat /tmp/bluetoothctl.log)" "[--][disconnect][AA:BB:CC:DD:EE:01]"
}

test_bluetooth_rejects_invalid_address() {
  local out
  bt_setup
  for cmd in connect disconnect remove; do
    out=$(sh "${SCRIPTS}/rocknix-bluetooth" ${cmd} 'aa:bb:cc:dd:ee:01; reboot' 2>&1)
    assert_contains "${out}" "Invalid device address format" "${cmd}"
  done
  [ -e /tmp/bluetoothctl.log ] && fail "bluetoothctl called with an invalid address: $(cat /tmp/bluetoothctl.log)"
  return 0
}

test_bluetooth_failures_exit_nonzero() {
  bt_setup
  touch /tmp/bt.fail
  sh "${SCRIPTS}/rocknix-bluetooth" connect AA:BB:CC:DD:EE:01 >/dev/null 2>&1 &&
    fail "connect exited 0 although bluetoothctl failed"
  sh "${SCRIPTS}/rocknix-bluetooth" trust AA:BB:CC:DD:EE:01 >/dev/null 2>&1 &&
    fail "trust exited 0 without a running agent"
  return 0
}

test_bluetooth_trust() {
  local out
  bt_setup
  out=$(sh "${SCRIPTS}/rocknix-bluetooth" trust AA:BB:CC:DD:EE:07 2>&1)
  assert_contains "${out}" "Bluetooth agent is not running"
  [ -e /run/bt_device ] && fail "requested pairing without an agent"
  echo $$ >/run/bt_agent_status
  echo "Pairing AA:BB:CC:DD:EE:07" >/run/bt_status
  bt_device AA:BB:CC:DD:EE:07 "Pro Controller" 0x002508 true
  out=$(timeout 10 sh "${SCRIPTS}/rocknix-bluetooth" trust AA:BB:CC:DD:EE:07)
  assert_contains "${out}" "Pairing AA:BB:CC:DD:EE:07"
  assert_eq "$(cat /run/bt_device)" "AA:BB:CC:DD:EE:07" "device handed to the agent"
  tar tf /storage/roms/backups/bluetooth.tar | grep -q 'EE:07/info' || fail "paired device not backed up"
}

test_bluetooth_enable_disable() {
  local out
  bt_setup
  settings 'controllers.bluetooth.enabled=0'
  stub /usr/bin/systemctl <<'EOF'
#!/bin/sh
echo "$*" >>/tmp/systemctl.log
[ "$*" = "start bluetooth-agent" ] && echo ${PPID} >/run/bt_agent_status
exit 0
EOF
  out=$(timeout 10 sh "${SCRIPTS}/rocknix-bluetooth" enable) || fail "enable failed: ${out}"
  assert_contains "${out}" "agent started successfully"
  assert_eq "$(grep '^controllers.bluetooth.enabled=' "${SYSCFG}")" "controllers.bluetooth.enabled=1"
  sh "${SCRIPTS}/rocknix-bluetooth" disable >/dev/null || fail "disable failed"
  assert_eq "$(grep '^controllers.bluetooth.enabled=' "${SYSCFG}")" "controllers.bluetooth.enabled=0"
  assert_eq "$(cat /tmp/systemctl.log)" "start bluetooth"$'\n'"start bluetooth-agent"$'\n'"stop bluetooth-agent"$'\n'"stop bluetooth"
}

test_bluetooth_live_devices() {
  local pid n=0
  bt_setup
  echo $$ >/run/bt_agent_status
  sh "${SCRIPTS}/rocknix-bluetooth" live_devices >live.out 2>&1 &
  pid=$!
  until [ "$(cat /run/bt_discovery_control 2>/dev/null)" = start ] && [ -s /run/bt_listing.pid ]; do
    n=$((n + 1))
    [ ${n} -lt 50 ] || { kill ${pid}; fail "live_devices did not start"; }
    sleep 0.1
  done
  echo '<device id="AA:BB:CC:DD:EE:09" name="8BitDo Pro 2" />' >>/run/bt_listing
  n=0
  until grep -q 'EE:09' live.out; do
    n=$((n + 1))
    [ ${n} -lt 50 ] || { kill ${pid}; fail "listing not streamed: $(cat live.out)"; }
    sleep 0.1
  done
  sh "${SCRIPTS}/rocknix-bluetooth" stop_live_devices
  n=0
  while kill -0 ${pid} 2>/dev/null; do
    n=$((n + 1))
    [ ${n} -lt 50 ] || { kill ${pid}; fail "live_devices did not stop"; }
    sleep 0.1
  done
  assert_eq "$(cat /run/bt_discovery_control)" stop "discovery stop signalled"
  [ -e /run/bt_listing ] || [ -e /run/bt_device ] || [ -e /run/bt_listing.pid ] && fail "listing files left in /run"
  return 0
}

test_amionline_offline() {
  local out rc
  no_route
  out=$(timeout 10 sh "${SCRIPTS}/amionline")
  rc=$?
  [ ${rc} -eq 124 ] && fail "amionline hangs without a network"
  assert_eq "${out}" false
  assert_eq "${rc}" 1 "exit status"
}

update_teardown() {
  unstub /usr/bin/curl /usr/bin/ping /usr/bin/df
  rm -rf /storage/.update /tmp/curl.* /tmp/df.avail
  rm -f "${SYSCFG}" "${MACHINEID}"
}

update_setup() {
  trap update_teardown EXIT
  rm -rf /storage/.update /tmp/curl.*
  settings "$@"
  mkdir -p "${MACHINEID%/*}"
  echo 0123456789abcdef0123456789abcdef >"${MACHINEID}"
  echo "https://example.invalid/ROCKNIX-SM8250.aarch64-20261010.tar" >/tmp/curl.reply
  echo 4096 >/tmp/df.avail
  printf '%s  ROCKNIX.tar\n' "$(printf payload | sha256sum | cut -d' ' -f1)" >/tmp/curl.sha256
  stub /usr/bin/curl <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '[%s]' "$a"; done; echo; } >>/tmp/curl.log
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    http*) url=$1 ;;
  esac
  shift
done
[ -z "${out}" ] && { cat /tmp/curl.reply; exit 0; }
case "${url}" in
  *.sha256) cat /tmp/curl.sha256 >"${out}" ;;
  *) printf payload >"${out}" ;;
esac
EOF
  stub /usr/bin/ping <<'EOF'
#!/bin/sh
exit 0
EOF
  stub /usr/bin/df <<'EOF'
#!/bin/sh
printf 'Filesystem           1M-blocks      Used Available Use%% Mounted on\n/dev/mmcblk0p2           60000        10 %8s   0%% /storage\n' "$(cat /tmp/df.avail)"
EOF
}

test_update_without_network() {
  local out rc
  no_route
  trap 'unstub /usr/bin/curl; rm -f /tmp/curl.log' EXIT
  rm -f /tmp/curl.log
  argv_stub /usr/bin/curl
  out=$(timeout 20 sh "${SCRIPTS}/rocknix-update" check)
  rc=$?
  assert_eq "${rc}" 1 "exit status"
  assert_eq "${out}" "Network connection unavailable."
  [ -e /tmp/curl.log ] && fail "contacted the update server without a network"
  return 0
}

test_update_check_reports_version() {
  local out log
  update_setup 'updates.branch=nightly' 'updates.force=0'
  out=$(sh "${SCRIPTS}/rocknix-update" check) || fail "check failed: ${out}"
  assert_eq "${out}" 20261010 "version parsed from the update URL"
  log=$(cat /tmp/curl.log)
  . /etc/os-release
  assert_contains "${log}" "[-X][POST]"
  assert_contains "${log}" "[-F][BRANCH=nightly]"
  assert_contains "${log}" "[-F][FORCE=0]"
  assert_contains "${log}" "[-F][UID=456789abcdef]"
  assert_contains "${log}" "[-F][SOC=${HW_DEVICE}]"
  assert_contains "${log}" "[-F][VERSION=${OS_VERSION}]"
  assert_contains "${log}" "[https://update.rocknix.org]"
  [ -e /storage/.update ] && fail "check created /storage/.update"
  return 0
}

test_update_check_no_update() {
  local out rc
  update_setup 'updates.branch=stable'
  echo "no update" >/tmp/curl.reply
  out=$(sh "${SCRIPTS}/rocknix-update" check)
  rc=$?
  assert_eq "${rc}" 1 "exit status"
  assert_eq "${out}" "No update available."
  assert_contains "$(cat /tmp/curl.log)" "[-F][BRANCH=stable]"
}

test_update_forced_version_verifies_checksum() {
  local out
  update_setup 'updates.branch=nightly' 'updates.force=1'
  out=$(sh "${SCRIPTS}/rocknix-update" 20261001) || fail "forced update failed: ${out}"
  assert_contains "$(head -n 1 /tmp/curl.log)" "[-F][FORCE=20261001]"
  assert_contains "${out}" "Checksum verified successfully"
  assert_eq "$(cat "/storage/.update/ROCKNIX-SM8250.aarch64-20261010.tar" 2>/dev/null)" payload "update file"
  assert_eq "$(grep '^updates.force=' "${SYSCFG}")" "updates.force=0" "force flag cleared"
}

test_update_bad_checksum_discards_download() {
  local out rc
  update_setup 'updates.branch=nightly' 'updates.force=1'
  echo "0000  ROCKNIX.tar" >/tmp/curl.sha256
  out=$(sh "${SCRIPTS}/rocknix-update" update)
  rc=$?
  assert_eq "${rc}" 1 "exit status"
  assert_contains "${out}" "Checksum verification failed"
  [ -n "$(ls -A /storage/.update 2>/dev/null)" ] && fail "kept a bad download: $(ls /storage/.update)"
  assert_eq "$(grep '^updates.force=' "${SYSCFG}")" "updates.force=1" "force flag kept"
}

test_update_needs_free_space() {
  local out rc
  update_setup 'updates.branch=nightly'
  echo 1500 >/tmp/df.avail
  out=$(sh "${SCRIPTS}/rocknix-update" update)
  rc=$?
  assert_eq "${rc}" 1 "exit status"
  assert_contains "${out}" "Not enough free space"
  assert_eq "$(grep -c '\[-o\]' /tmp/curl.log)" 0 "downloads started"
}

usb_setup() {
  local d
  for d in /sys/class/udc/* /sys/class/usb_role/* /sys/class/typec/*; do
    [ -e "${d}" ] && skip "the host exposes ${d}"
  done
  trap 'unstub /usr/sbin/modprobe; rm -rf /storage/.cache/usbgadget; rm -f "${MACHINEID}"' EXIT
  argv_stub /usr/sbin/modprobe
  mkdir -p /storage/.cache/usbgadget
  echo 0123456789abcdef0123456789abcdef >"${MACHINEID}"
}

test_usbgadget_reports_modes() {
  usb_setup
  assert_eq "$(sh "${SCRIPTS}/usbgadget" --options)" "disabled network file_transfer"
  assert_eq "$(sh "${SCRIPTS}/usbgadget")" disabled "mode without a UDC"
  printf 'IP=10.1.1.2\nNETMASK=255.255.255.0\nHOSTIP=${IP%%.*}.$((${IP##*.}-1))\n' >/storage/.cache/usbgadget/network.conf
  assert_eq "$(sh "${SCRIPTS}/usbgadget" address)" 10.1.1.2
}

test_usbgadget_disabled_persists_mode() {
  usb_setup
  echo USB_MODE=cdc >/storage/.cache/usbgadget/usbgadget.conf
  sh "${SCRIPTS}/usbgadget" disabled >/dev/null 2>&1
  assert_eq "$(cat /storage/.cache/usbgadget/usbgadget.conf)" USB_MODE=disabled
}

test_usbgadget_network_without_udc() {
  local err rc
  usb_setup
  echo USB_MODE=disabled >/storage/.cache/usbgadget/usbgadget.conf
  err=$(sh "${SCRIPTS}/usbgadget" network 2>&1 >/dev/null)
  rc=$?
  assert_eq "${rc}" 5 "exit status"
  assert_contains "${err}" "no UDC available"
  assert_eq "$(cat /storage/.cache/usbgadget/usbgadget.conf)" USB_MODE=disabled "stored mode"
}
