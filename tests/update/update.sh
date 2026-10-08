# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

. /etc/os-release
OLD=/oldinit
UPDATE_SH=${REPO}/projects/ROCKNIX/devices/${HW_DEVICE}/bootloader/update.sh
ABL=/usr/share/bootloader/rocknix_abl/abl_signed-${HW_DEVICE}.elf

old_root_up() {
  rm -rf "${OLD}" && cp -a /oldinit-src "${OLD}"
  mkdir -p "${OLD}/proc" "${OLD}/sys" "${OLD}/dev" "${OLD}/update" "${OLD}/flash" "${OLD}/storage" "${OLD}/tmp"
  mount -t proc proc "${OLD}/proc"
  mount -t sysfs sysfs "${OLD}/sys"
  mount --rbind /dev "${OLD}/dev"
  mount --bind / "${OLD}/update"
  mount -o remount,bind,ro "${OLD}/update"
  mount -t tmpfs tmpfs "${OLD}/flash"
  mount -t tmpfs tmpfs "${OLD}/storage"
  mount -t tmpfs tmpfs "${OLD}/tmp"
  [ -f "${UPDATE_SH}" ] && cp "${UPDATE_SH}" /usr/share/bootloader/update.sh
  trap old_root_down EXIT
}

old_root_down() {
  for m in tmp storage flash update dev sys proc; do umount -l "${OLD}/${m}" 2>/dev/null; done
  [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null && rm -f "${LOOP}"p*
}

in_old_initramfs() {
  chroot "${OLD}" /usr/bin/busybox sh -c "export PATH=/usr/bin:/usr/sbin SYSTEM_ROOT=/update BOOT_ROOT=/flash; $*"
}

abl_disk() {
  local p n
  python3 "${TESTS}/lib/mkgpt.py" disk.img 64 abl_a:16 abl_b:16
  LOOP=$(attach_loop disk.img) || fail "no free loop device"
  for p in 1 2; do
    n=/sys/class/block/${LOOP#/dev/}p${p}/dev
    for _ in 1 2 3 4 5; do [ -f "${n}" ] && break; sleep 0.2; done
    rm -f "${LOOP}p${p}"
    mknod "${LOOP}p${p}" b $(tr ':' ' ' <"${n}")
  done
}

test_update_sh_commands_exist_in_old_initramfs() {
  local cmd where missing="" have
  [ -f "${UPDATE_SH}" ] || skip "no bootloader/update.sh for ${HW_DEVICE}"
  have=" $(chroot /oldinit-src /usr/bin/busybox --list | tr '\n' ' ') $(ls /oldinit-src/usr/bin /oldinit-src/usr/sbin | tr '\n' ' ') "
  while IFS="$(printf '\t')" read -r cmd where; do
    case " case cd echo eval exec exit export false for local printf pwd read return select set shift test trap true while [ . : " in
      *" ${cmd} "*) continue ;;
    esac
    case "${have}" in *" ${cmd} "*) continue ;; esac
    missing="${missing}${cmd} (${where})"$'\n'
  done < <(python3 "${TESTS}/lib/scan_commands.py" commands "${REPO}" "${UPDATE_SH#${REPO}/}")
  [ -z "${missing}" ] || fail "update.sh runs in the previous release's initramfs, which lacks:"$'\n'"${missing}"
}

test_update_sh_runs_in_old_initramfs() {
  local out
  [ -f "${UPDATE_SH}" ] || skip "no bootloader/update.sh for ${HW_DEVICE}"
  old_root_up
  [ -f "${ABL}" ] && abl_disk
  out=$(in_old_initramfs "sh /update/usr/share/bootloader/update.sh" 2>&1)
  echo "${out}"
  case "${out}" in *"Error"*|*"not found"*|*"applet not found"*) fail "update.sh reported errors" ;; esac
}

test_updateabl_flashes_from_old_initramfs() {
  local out size p
  [ -f "${ABL}" ] || skip "${HW_DEVICE} has no rocknix_abl"
  old_root_up
  abl_disk
  out=$(in_old_initramfs "/update/usr/bin/updateabl" 2>&1)
  echo "${out}"
  size=$(stat -c %s "${ABL}")
  for p in 1 2; do
    cmp -s -n "${size}" "${ABL}" "${LOOP}p${p}" || fail "abl partition ${p} does not hold the new ABL"
  done
}
