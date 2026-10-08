# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

. /etc/os-release
IMAGE_SCRIPT_DIRS="usr/bin usr/sbin usr/lib/autostart/common usr/lib/autostart/daemons usr/lib/autostart/quirks/devices
  usr/lib/autostart/quirks/platforms/${HW_DEVICE} usr/lib/rocknix usr/lib/systemd/system-sleep etc/profile.d"

UNSAFE_APPLETS=" kill killall killall5 pkill halt reboot poweroff vi less more watch top login su passwd telnet
  httpd ntpd udhcpd udhcpc nc ftpget ftpput inotifyd ifplugd nbd-client switch_root init dd "

test_applet_options_parse() {
  local applets applet opt where out failures=""
  applets=" $(busybox --list | tr '\n' ' ') "
  mkdir -p scratch
  while IFS="$(printf '\t')" read -r applet opt where; do
    case "${applets}" in *" ${applet} "*) ;; *) continue ;; esac
    case "${UNSAFE_APPLETS}" in *" ${applet} "*) continue ;; esac
    known_failure "${TESTS}/userspace/busybox.known" "${applet} ${opt}" && continue
    if [ "${applet}" = "find" ]; then
      out=$(cd scratch && timeout 3 busybox find . "${opt}" 1 </dev/null 2>&1 >/dev/null)
      case "${out}" in *"unrecognized: ${opt}"*) ;; *) continue ;; esac
    else
      out=$(cd scratch && timeout 3 busybox "${applet}" "${opt}" 1 /dev/null </dev/null 2>&1 >/dev/null)
      case "${out}" in *"invalid option"*|*"unrecognized option"*) ;; *) continue ;; esac
    fi
    failures="${failures}${applet} ${opt} (${where}): ${out%%$'\n'*}"$'\n'
  done < <(python3 "${TESTS}/lib/scan_commands.py" options "${REPO}" projects/ROCKNIX)
  [ -z "${failures}" ] || fail "options rejected by busybox $(busybox | head -n 1 | cut -d' ' -f2):"$'\n'"${failures}"
}

test_commands_exist() {
  local cmd where failures="" builtins
  builtins=" alias bg bind break builtin caller cd command compgen complete continue declare dirs disown echo enable
    eval exec exit export false fc fg getopts hash help history jobs kill let local logout mapfile popd printf pushd
    pwd read readarray readonly return set shift shopt source suspend test times trap true type typeset ulimit umask
    unalias unset wait [ [[ . : "
  PATH="${PATH}$(printf ':%s' /usr/lib/autostart/quirks/*/*/bin)"
  while IFS="$(printf '\t')" read -r cmd where; do
    case "${builtins}" in *" ${cmd} "*) continue ;; esac
    case "${cmd}" in *[!A-Za-z0-9._+-]*|[0-9]*|"") continue ;; esac
    command -v "${cmd}" >/dev/null && continue
    known_failure "${TESTS}/userspace/commands.known" "${cmd}" && continue
    failures="${failures}${cmd} (${where})"$'\n'
  done < <(python3 "${TESTS}/lib/scan_commands.py" --owned "${REPO}" commands / ${IMAGE_SCRIPT_DIRS})
  [ -z "${failures}" ] || fail "commands not found in the image:"$'\n'"${failures}"
}
