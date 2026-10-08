# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

OLD=/oldinit
DEVICES=${REPO}/projects/ROCKNIX/devices
DTHELPER=${REPO}/projects/ROCKNIX/packages/sysutils/busybox/scripts/dthelper
PART_START=$(sed -n 's/^ *SYSTEM_PART_START=\([0-9]*\).*/\1/p' "${REPO}/distributions/ROCKNIX/options")
FAT_MB=32
DISK_MB=$(((PART_START + 2047) / 2048 + FAT_MB + 4 + 1))
MMC=/dev/mmcblk9
UART2=ff160000
UART5=ff178000

put() {
  local f=$1
  shift
  mkdir -p "$(dirname "${f}")"
  printf '%s\n' "$@" >"${f}"
}

blob() {
  mkdir -p "$(dirname "$1")"
  python3 -c 'import os, sys; m = sys.argv[1].encode() + b"\n"; open(sys.argv[1], "wb").write(m + os.urandom(int(sys.argv[2]) - len(m)))' "$1" "$2"
}

old_root_down() {
  local m
  for m in flash tmp storage update sys dev proc .proc; do umount -l "${OLD}/${m}" 2>/dev/null; done
}

cleanup() {
  old_root_down
  umount "${FAT}" 2>/dev/null
  [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null
  rm -f "${MMC}" "${MMC}p1"
}

settle() {
  for _ in $(seq 30); do
    python3 -c 'import os, sys; os.close(os.open(sys.argv[1], os.O_RDONLY | os.O_EXCL))' "${MMC}p1" 2>/dev/null && return
    sleep 1
  done
}

retry() {
  for _ in 1 2 3; do "$@" && return; settle; done
  return 1
}

fsck_boot() {
  fsck.vfat -n "${MMC}p1" >fsck.out 2>&1
}

make_disk() {
  local n p1
  dd if=/dev/urandom of=disk.img bs=1M count=${DISK_MB} 2>/dev/null
  python3 "${TESTS}/lib/mkgpt.py" $([ "${LABEL}" = msdos ] && echo --msdos) --start "${PART_START}" \
    disk.img ${DISK_MB} system:${FAT_MB} storage:4
  LOOP=$(attach_loop disk.img) || fail "no free loop device"
  n=/sys/class/block/${LOOP#/dev/}
  p1=${n}/${LOOP#/dev/}p1/dev
  for _ in $(seq 25); do [ -f "${p1}" ] && break; sleep 0.2; done
  [ -f "${p1}" ] || fail "${LOOP} has no partitions"
  rm -f "${MMC}" "${MMC}p1"
  mknod "${MMC}" b $(tr ':' ' ' <"${n}/dev")
  mknod "${MMC}p1" b $(tr ':' ' ' <"${p1}")
  retry mkfs.vfat -n ROCKNIX "${MMC}p1" >/dev/null || fail "mkfs.vfat ${MMC}p1 failed"
  mkdir -p "${FAT}"
  retry mount "${MMC}p1" "${FAT}" || fail "cannot mount ${MMC}p1"
}

setup() {
  DEV=$1
  UPDATE_SH=${DEVICES}/${DEV}/bootloader/update.sh
  [ -f "${UPDATE_SH}" ] || skip "no bootloader/update.sh for ${DEV}"
  FAT=${PWD}/fat
  SYS=${PWD}/sys
  BL=${PWD}/system/usr/share/bootloader
  LABEL=$(sed -n 's/^ *PARTITION_TABLE="\(.*\)"/\1/p' "${DEVICES}/${DEV}/options")
  CMDLINE="boot=LABEL=ROCKNIX disk=LABEL=STORAGE quiet"
  trap cleanup EXIT
  make_disk
  mkdir -p "${BL}" "${SYS}" system/usr/bin
  cp "${UPDATE_SH}" "${BL}/update.sh"
  cp "${DTHELPER}" system/usr/bin/dthelper
  chmod 755 system/usr/bin/dthelper
  ln -s dthelper system/usr/bin/dtname
  ln -s dthelper system/usr/bin/dtsoc
  put "${FAT}/KERNEL" "kernel old"
  put "${FAT}/SYSTEM" "system old"
}

compatible() {
  mkdir -p "${SYS}/firmware/devicetree/base"
  printf '%s\0' "$@" >"${SYS}/firmware/devicetree/base/compatible"
}

console() {
  local base dir
  rm -rf "${SYS}/devices/platform"
  for base in ${UART2}:ttyS2 ${UART5}:ttyS5; do
    dir=${SYS}/devices/platform/${base%:*}.serial/${base%:*}.serial:0/${base%:*}.serial:0.0/tty/${base#*:}
    mkdir -p "${dir}"
    echo "0x${base%:*}" | tr a-f A-F >"${dir}/iomem_base"
    if [ "${base%:*}" = "$1" ]; then echo Y >"${dir}/console"; else echo N >"${dir}/console"; fi
  done
}

regulator() {
  mkdir -p "${SYS}/class/regulator/$1"
  echo "$2" >"${SYS}/class/regulator/$1/name"
  echo "$3" >"${SYS}/class/regulator/$1/microvolts"
}

old_root_up() {
  local e
  old_root_down
  rm -rf "${OLD}" && cp -a /oldinit-src "${OLD}"
  mkdir -p "${OLD}/.proc" "${OLD}/proc" "${OLD}/sys" "${OLD}/dev" "${OLD}/update" "${OLD}/flash" "${OLD}/storage" "${OLD}/tmp"
  mount -t proc proc "${OLD}/.proc"
  mount -t tmpfs tmpfs "${OLD}/proc"
  for e in "${OLD}"/.proc/*; do
    case "${e##*/}" in [0-9]*|cmdline|device-tree) ;; *) ln -s "/.proc/${e##*/}" "${OLD}/proc/${e##*/}" ;; esac
  done
  ln -s /sys/firmware/devicetree/base "${OLD}/proc/device-tree"
  echo "${CMDLINE}" >"${OLD}/proc/cmdline"
  mount --bind "${SYS}" "${OLD}/sys"
  mount --rbind /dev "${OLD}/dev"
  mount --bind "${PWD}/system" "${OLD}/update"
  mount -o remount,bind,ro "${OLD}/update"
  mount -t tmpfs tmpfs "${OLD}/storage"
  mount -t tmpfs tmpfs "${OLD}/tmp"
}

in_old_initramfs() {
  timeout 300 chroot "${OLD}" /usr/bin/busybox sh -c "export PATH=/usr/bin:/usr/sbin SYSTEM_ROOT=/update BOOT_ROOT=/flash; $*"
}

run_update() {
  umount "${FAT}"
  cp disk.img before.img
  old_root_up
  retry in_old_initramfs "mount -o ro,noatime ${MMC}p1 /flash" || fail "the old initramfs cannot mount the boot partition"
  in_old_initramfs "sh /update/usr/share/bootloader/update.sh" </dev/null >out 2>err
  RC=$?
  sed 's/^/stdout: /' out
  sed 's/^/stderr: /' err
  FLASH_OPTS=$(awk -v m="${OLD}/flash" '$2 == m {print $4}' /proc/mounts)
  HINT=$(cat "${OLD}/storage/.boot.hint" 2>/dev/null)
  umount "${OLD}/flash"
  retry fsck_boot
  FSCK_RC=$?
  retry mount -o ro "${MMC}p1" "${FAT}" || fail "the boot partition does not mount after the update:"$'\n'"$(cat fsck.out)"
  sync
}

assert_clean_run() {
  local errors
  errors=$(grep -vE '^[0-9]+\+[0-9]+ records (in|out)$|^[0-9]+ bytes .* copied' err)
  [ -z "${errors}" ] || fail "update.sh wrote to stderr in the old initramfs:"$'\n'"${errors}"
  assert_eq "${RC}" 0 "update.sh exit status"
  assert_eq "${HINT}" UPDATE "/storage/.boot.hint"
  case "${FLASH_OPTS}" in ro,*) ;; *) fail "update.sh left /flash mounted ${FLASH_OPTS:-nowhere}" ;; esac
  if grep -q 'echo "DONE"' "${UPDATE_SH}"; then
    assert_eq "$(tail -n 1 out)" DONE "last line of update.sh output"
  fi
}

# check_disk [offset:file]...: each file sits at its offset, the partition tables and FAT are
# intact and nothing else on the disk changed.
check_disk() {
  local out
  [ "${FSCK_RC}" = 0 ] || fail "fsck.vfat after the update:"$'\n'"$(cat fsck.out)"
  out=$(python3 - "${LABEL}" "${PART_START}" $((FAT_MB * 1024 * 1024)) before.img disk.img "$@" <<'EOF'
import struct
import sys
import zlib

label, start, size = sys.argv[1], int(sys.argv[2]) * 512, int(sys.argv[3])
old, new = open(sys.argv[4], "rb").read(), open(sys.argv[5], "rb").read()
end = start + size
errors = []


def first_diff(a, b, base):
    for i in range(0, max(len(a), len(b)), 65536):
        if a[i:i + 65536] != b[i:i + 65536]:
            j = i
            while j < min(len(a), len(b)) and a[j] == b[j]:
                j += 1
            return base + j
    return None


def region(at):
    if at < 512:
        return "MBR"
    if label == "gpt" and at < 34 * 512:
        return "primary GPT"
    if at < start:
        return "before the boot partition"
    if label == "gpt" and at >= len(old) - 33 * 512:
        return "backup GPT"
    return "storage partition"


skip = [(start, end)]
for arg in sys.argv[6:]:
    off, path = arg.split(":", 1)
    off, data = int(off), open(path, "rb").read()
    at = first_diff(new[off:off + len(data)], data, off)
    if at is not None:
        errors.append(f"{path} is not at byte {off} (first difference at byte {at})")
    skip.append((off, off + len(data)))

if len(new) != len(old):
    errors.append(f"disk size changed from {len(old)} to {len(new)}")
pos = 0
for s, e in sorted(skip) + [(len(old), len(old))]:
    if s > pos:
        at = first_diff(new[pos:s], old[pos:s], pos)
        if at is not None:
            errors.append(f"byte {at} changed ({region(at)})")
    pos = max(pos, e)

if new[510:512] != b"\x55\xaa":
    errors.append("MBR signature damaged")
if label == "msdos":
    if struct.unpack_from("<I", new, 454)[0] * 512 != start:
        errors.append("MBR: partition 1 moved")
else:
    for lba, name in ((1, "primary"), (len(new) // 512 - 1, "backup")):
        hdr = bytearray(new[lba * 512:lba * 512 + 92])
        crc = struct.unpack_from("<I", hdr, 16)[0]
        struct.pack_into("<I", hdr, 16, 0)
        if hdr[:8] != b"EFI PART" or zlib.crc32(hdr) != crc:
            errors.append(f"{name} GPT header damaged")
            continue
        entries_lba, count, entry_size, entries_crc = struct.unpack_from("<QIII", hdr, 72)
        entries = new[entries_lba * 512:entries_lba * 512 + count * entry_size]
        if zlib.crc32(entries) != entries_crc:
            errors.append(f"{name} GPT entries damaged")
        elif struct.unpack_from("<Q", entries, 32)[0] * 512 != start:
            errors.append(f"{name} GPT: partition 1 moved")
print("\n".join(errors))
sys.exit(1 if errors else 0)
EOF
  ) || fail "disk after the update:"$'\n'"${out}"
}

written_at() {
  local off=$1 f
  shift
  for f in "$@"; do
    cmp -s -n "$(stat -c %s "${f}")" "${f}" disk.img 0 "${off}" && { basename "${f}"; return; }
  done
  echo none
}

assert_same() {
  cmp -s "$1" "$2" || fail "${2#${PWD}/} is not ${1#${PWD}/}: [$(head -c 64 "$2" 2>&1)]"
}

scan_update_scripts() {
  python3 "${TESTS}/lib/scan_commands.py" "$1" "${REPO}" $(cd "${REPO}" && ls projects/ROCKNIX/devices/*/bootloader/update.sh)
}

test_commands_exist_in_old_initramfs() {
  local cmd where missing="" have
  have=" $(chroot /oldinit-src /usr/bin/busybox --list | tr '\n' ' ') $(ls /oldinit-src/usr/bin /oldinit-src/usr/sbin | tr '\n' ' ') "
  while IFS="$(printf '\t')" read -r cmd where; do
    case " break case cd continue echo eval exec exit export false for getopts local printf pwd read readonly return select
      set shift test trap true type ulimit umask unset wait while [ . : " in
      *" ${cmd} "*) continue ;;
    esac
    case "${have}" in *" ${cmd} "*) continue ;; esac
    missing="${missing}${cmd} (${where})"$'\n'
  done < <(scan_update_scripts commands)
  [ -z "${missing}" ] || fail "bootloader update.sh runs in the previous release's initramfs, which lacks:"$'\n'"${missing}"
}

test_options_accepted_by_old_initramfs() {
  local applet opt where out failures="" applets
  applets=" $(chroot /oldinit-src /usr/bin/busybox --list | tr '\n' ' ') "
  old_root_down
  rm -rf "${OLD}" && cp -a /oldinit-src "${OLD}"
  mkdir -p "${OLD}/dev" "${OLD}/tmp/scratch"
  mknod "${OLD}/dev/null" c 1 3
  touch "${OLD}/tmp/scratch/f"
  while IFS="$(printf '\t')" read -r applet opt where; do
    case "${applets}" in *" ${applet} "*) ;; *) continue ;; esac
    case " mount umount dd rm mv halt reboot poweroff kill killall " in *" ${applet} "*) continue ;; esac
    out=$(timeout 5 chroot "${OLD}" /usr/bin/busybox sh -c 'cd /tmp/scratch && exec /usr/bin/busybox "$@" 1 f' sh \
      "${applet}" "${opt}" </dev/null 2>&1 >/dev/null)
    case "${out}" in *"invalid option"*|*"unrecognized option"*) ;; *) continue ;; esac
    failures="${failures}${applet} ${opt} (${where}): ${out%%$'\n'*}"$'\n'
  done < <(scan_update_scripts options)
  [ -z "${failures}" ] || fail "options rejected by the previous release's initramfs:"$'\n'"${failures}"
}

rk3326_files() {
  local d
  for d in rk3326-anbernic-rg351m rk3326-odroid-go2 rk3326-powkiddy-rgb10x; do
    put "${FAT}/${d}.dtb" "dtb ${d} old"
    put "${BL}/device_trees/${d}.dtb" "dtb ${d} new"
  done
  put "${BL}/device_trees/rk3326-gameconsole-r36s.dtb" "dtb rk3326-gameconsole-r36s new"
  put "${FAT}/overlays/README.txt" "overlays old"
  put "${BL}/overlays/README.txt" "overlays new"
  put "${BL}/overlays/mipi-panel.dtbo" "dtbo mipi-panel new"
  put "${FAT}/stock/README.txt" "stock"
  put "${BL}/stock/README.txt" "stock"
  put "${FAT}/extlinux/extlinux.conf" "LABEL ROCKNIX" "  LINUX /KERNEL" "  FDT /rk3326-user-choice.dtb"
  put "${BL}/extlinux/extlinux.conf" "LABEL ROCKNIX" "  LINUX /KERNEL" "  FDTDIR /"
  put "${BL}/extlinux/extlinux.conf.r36s" "LABEL ROCKNIX" "  LINUX /KERNEL" "  FDT /rk3326-gameconsole-r36s.dtb"
  put "${BL}/a_boot.scr" "a_boot.scr new setenv fdtfile rk3326-anbernic-rg351m.dtb"
  put "${BL}/b_boot.scr" "b_boot.scr new setenv fdtfile rk3326-powkiddy-rgb10x.dtb"
  case "$1" in
    a) put "${FAT}/boot.scr" "a_boot.scr old setenv fdtfile rk3326-anbernic-rg351m.dtb" ;;
    b) put "${FAT}/boot.scr" "b_boot.scr old setenv fdtfile rk3326-powkiddy-rgb10x.dtb" ;;
  esac
  blob "${BL}/a_uboot.bin" 4400001
  blob "${BL}/b_uboot.bin" $((24512 * 512 + 4 * 1024 * 1024))
  blob "${BL}/b_uboot.bin.uart5" 5000005
  console ${UART2}
}

rk3326_uboot() {
  written_at $((64 * 512)) "${BL}/a_uboot.bin" "${BL}/b_uboot.bin" "${BL}/b_uboot.bin.uart5"
}

test_rk3326_runs_clean() {
  setup RK3326
  rk3326_files a
  CMDLINE="${CMDLINE} uboot.hwid_adc=a,812"
  run_update
  assert_clean_run
}

test_rk3326_a_uboot_at_sector_64() {
  setup RK3326
  rk3326_files a
  CMDLINE="${CMDLINE} uboot.hwid_adc=a,812"
  run_update
  assert_eq "$(rk3326_uboot)" a_uboot.bin "u-boot at sector 64"
  check_disk $((64 * 512)):"${BL}/a_uboot.bin"
}

test_rk3326_b_uboot_fills_gap_to_boot_partition() {
  setup RK3326
  rk3326_files b
  CMDLINE="${CMDLINE} uboot.hwid_adc=b,1023"
  run_update
  assert_eq $((64 * 512 + $(stat -c %s "${BL}/b_uboot.bin"))) $((PART_START * 512)) "end of b_uboot.bin"
  assert_eq "$(rk3326_uboot)" b_uboot.bin "u-boot at sector 64"
  check_disk $((64 * 512)):"${BL}/b_uboot.bin"
}

test_rk3326_uart5_console_gets_uart5_uboot() {
  setup RK3326
  rk3326_files b
  console ${UART5}
  CMDLINE="${CMDLINE} uboot.hwid_adc=b,1023"
  run_update
  assert_eq "$(rk3326_uboot)" b_uboot.bin.uart5 "u-boot at sector 64"
  assert_contains "$(cat "${FAT}/update.log")" "Detected UART5 console"
  check_disk $((64 * 512)):"${BL}/b_uboot.bin.uart5"
}

test_rk3326_boot_files() {
  local d
  setup RK3326
  rk3326_files a
  CMDLINE="${CMDLINE} uboot.hwid_adc=a,812"
  run_update
  for d in rk3326-anbernic-rg351m rk3326-odroid-go2 rk3326-powkiddy-rgb10x rk3326-gameconsole-r36s; do
    assert_same "${BL}/device_trees/${d}.dtb" "${FAT}/${d}.dtb"
  done
  assert_same "${BL}/overlays/mipi-panel.dtbo" "${FAT}/overlays/mipi-panel.dtbo"
  assert_same "${BL}/overlays/README.txt" "${FAT}/overlays/README.txt"
  assert_same "${BL}/a_boot.scr" "${FAT}/boot.scr"
  assert_contains "$(cat "${FAT}/extlinux/extlinux.conf")" "FDT /rk3326-user-choice.dtb" "existing extlinux.conf"
  [ -e "${FAT}/extlinux/extlinux.conf.r36s" ] && fail "extlinux files copied over an existing extlinux.conf"
  assert_contains "$(cat "${FAT}/update.log")" "Subdevice from cmdline: a"
  assert_contains "$(cat "${FAT}/update.log")" "Updating a_uboot.bin on ${MMC}..."
}

test_rk3326_extlinux_created_when_missing() {
  setup RK3326
  rk3326_files a
  rm -r "${FAT}/extlinux"
  CMDLINE="${CMDLINE} uboot.hwid_adc=a,812"
  run_update
  assert_same "${BL}/extlinux/extlinux.conf" "${FAT}/extlinux/extlinux.conf"
  assert_same "${BL}/extlinux/extlinux.conf.r36s" "${FAT}/extlinux/extlinux.conf.r36s"
}

test_rk3326_device_trees_dir_flattened() {
  setup RK3326
  rk3326_files a
  mkdir "${FAT}/device_trees"
  mv "${FAT}/rk3326-odroid-go2.dtb" "${FAT}/device_trees/"
  put "${FAT}/device_trees/rk3326-only-here.dtb" "dtb rk3326-only-here old"
  CMDLINE="${CMDLINE} uboot.hwid_adc=a,812"
  run_update
  [ -e "${FAT}/device_trees" ] && fail "device_trees is still on the boot partition"
  assert_same "${BL}/device_trees/rk3326-odroid-go2.dtb" "${FAT}/rk3326-odroid-go2.dtb"
  assert_eq "$(cat "${FAT}/rk3326-only-here.dtb")" "dtb rk3326-only-here old" "dtb moved out of device_trees"
}

test_rk3326_subdevice_a_from_boot_scr() {
  setup RK3326
  rk3326_files a
  run_update
  assert_contains "$(cat "${FAT}/update.log")" "Subdevice from boot.scr: a"
  assert_eq "$(rk3326_uboot)" a_uboot.bin "u-boot at sector 64"
  assert_same "${BL}/a_boot.scr" "${FAT}/boot.scr"
}

test_rk3326_subdevice_b_from_boot_scr() {
  setup RK3326
  rk3326_files b
  run_update
  assert_contains "$(cat "${FAT}/update.log")" "Subdevice from boot.scr: b"
  assert_eq "$(rk3326_uboot)" b_uboot.bin "u-boot at sector 64"
  assert_same "${BL}/b_boot.scr" "${FAT}/boot.scr"
}

test_rk3326_subdevice_from_boot_ini() {
  setup RK3326
  rk3326_files none
  put "${FAT}/boot.ini" "odroidgoa-uboot-config" 'load mmc 1:1 ${dtb_loadaddr} rk3326-anbernic-rg351m.dtb'
  run_update
  assert_contains "$(cat "${FAT}/update.log")" "Subdevice from boot.ini: a"
  assert_eq "$(rk3326_uboot)" a_uboot.bin "u-boot at sector 64"
  assert_same "${BL}/a_boot.scr" "${FAT}/boot.scr"
  [ -e "${FAT}/boot.ini" ] && fail "boot.ini left in place next to boot.scr"
  assert_contains "$(cat "${FAT}/boot.ini.bak")" "rk3326-anbernic-rg351m.dtb" "boot.ini.bak"
}

test_rk3326_subdevice_fallback() {
  setup RK3326
  rk3326_files none
  run_update
  assert_contains "$(cat "${FAT}/update.log")" "Subdevice fallback: a"
  assert_eq "$(rk3326_uboot)" a_uboot.bin "u-boot at sector 64"
  assert_same "${BL}/a_boot.scr" "${FAT}/boot.scr"
}

rk_files() {
  local dtb=$1 fdt=$2 dir=/device_trees
  put "${BL}/device_trees/${dtb}.dtb" "dtb ${dtb} new"
  put "${BL}/device_trees/other-board.dtb" "dtb other-board new"
  put "${BL}/overlays/panel.dtbo" "dtbo panel new"
  put "${FAT}/overlays/user.dtbo" "dtbo user old"
  if [ "$3" = legacy ]; then
    dir=""
    put "${FAT}/${dtb}.dtb" "dtb ${dtb} old"
  else
    put "${FAT}/device_trees/${dtb}.dtb" "dtb ${dtb} old"
  fi
  case "${fdt}" in
    FDT) fdt="FDT ${dir}/${dtb}.dtb" ;;
    FDTDIR) fdt="FDTDIR ${dir:-/}" ;;
  esac
  put "${FAT}/extlinux/extlinux.conf" "LABEL ROCKNIX" "  LINUX /KERNEL" "  ${fdt}" "  APPEND quiet"
}

assert_rk_boot_files() {
  assert_same "${BL}/device_trees/$1.dtb" "${FAT}/device_trees/$1.dtb"
  assert_same "${BL}/device_trees/other-board.dtb" "${FAT}/device_trees/other-board.dtb"
  assert_same "${BL}/overlays/panel.dtbo" "${FAT}/overlays/panel.dtbo"
  assert_eq "$(cat "${FAT}/overlays/user.dtbo")" "dtbo user old" "overlay not shipped by the update"
}

assert_rk_migrated() {
  [ -e "${FAT}/$1.dtb" ] && fail "$1.dtb left in the root of the boot partition"
  assert_same "${BL}/device_trees/$1.dtb" "${FAT}/device_trees/$1.dtb"
  assert_contains "$(cat "${FAT}/extlinux/extlinux.conf")" "$2"
}

uboot_bin_setup() {
  setup "$1"
  DTB=$2
  shift 2
  [ $# -eq 0 ] || compatible "$@"
  rk_files "${DTB}" FDT "${LAYOUT}"
  blob "${BL}/uboot.bin" 9986561
}

uboot_bin_runs_clean() {
  uboot_bin_setup "$@"
  run_update
  assert_clean_run
}

uboot_bin_at_sector_64() {
  uboot_bin_setup "$@"
  run_update
  assert_eq "$(written_at $((64 * 512)) "${BL}/uboot.bin")" uboot.bin "u-boot at sector 64"
  check_disk $((64 * 512)):"${BL}/uboot.bin"
}

uboot_bin_boot_files() {
  uboot_bin_setup "$@"
  run_update
  assert_rk_boot_files "${DTB}"
  assert_contains "$(cat "${FAT}/extlinux/extlinux.conf")" "  FDT /device_trees/${DTB}.dtb"
}

uboot_bin_device_trees_migrated() {
  LAYOUT=legacy uboot_bin_setup "$@"
  run_update
  assert_rk_migrated "${DTB}" "  FDT /device_trees/${DTB}.dtb"
}

RK3399="RK3399 rk3399-anbernic-rg552 anbernic,rg552 rockchip,rk3399"
RK3576="RK3576 rk3576-anbernic-rg-vita-pro"
RK3588="RK3588 rk3588s-gameforce-ace gameforce,ace rockchip,rk3588s"

test_rk3399_runs_clean() { uboot_bin_runs_clean ${RK3399}; }
test_rk3399_uboot_at_sector_64() { uboot_bin_at_sector_64 ${RK3399}; }
test_rk3399_boot_files() { uboot_bin_boot_files ${RK3399}; }
test_rk3399_device_trees_migrated() { uboot_bin_device_trees_migrated ${RK3399}; }

test_rk3576_runs_clean() { uboot_bin_runs_clean ${RK3576}; }
test_rk3576_uboot_at_sector_64() { uboot_bin_at_sector_64 ${RK3576}; }
test_rk3576_boot_files() { uboot_bin_boot_files ${RK3576}; }
test_rk3576_device_trees_migrated() { uboot_bin_device_trees_migrated ${RK3576}; }

test_rk3588_runs_clean() { uboot_bin_runs_clean ${RK3588}; }
test_rk3588_uboot_at_sector_64() { uboot_bin_at_sector_64 ${RK3588}; }
test_rk3588_boot_files() { uboot_bin_boot_files ${RK3588}; }
test_rk3588_device_trees_migrated() { uboot_bin_device_trees_migrated ${RK3588}; }

rk3566_files() {
  compatible powkiddy,rgb30 rockchip,rk3566
  rk_files rk3566-powkiddy-rgb30 FDTDIR "$1"
  blob "${BL}/Generic_uboot.bin" 9986560
  blob "${BL}/Specific_uboot.bin" 9528320
}

test_rk3566_runs_clean() {
  setup RK3566
  rk3566_files
  run_update
  assert_clean_run
}

test_rk3566_disk_untouched() {
  setup RK3566
  rk3566_files
  run_update
  check_disk
}

test_rk3566_boot_files() {
  setup RK3566
  rk3566_files
  run_update
  assert_rk_boot_files rk3566-powkiddy-rgb30
}

test_rk3566_device_trees_migrated() {
  setup RK3566
  rk3566_files legacy
  run_update
  assert_rk_migrated rk3566-powkiddy-rgb30 "  FDTDIR /device_trees"
}

s922x_files() {
  local d
  for d in meson-g12b-odroid-go-ultra meson-g12b-powkiddy-rgb10-max-3-pro; do
    put "${FAT}/${d}.dtb" "dtb ${d} old"
    put "${BL}/${d}.dtb" "dtb ${d} new"
  done
  put "${BL}/meson-g12b-not-installed.dtb" "dtb meson-g12b-not-installed new"
  put "${BL}/overlays/panel.dtbo" "dtbo panel new"
  put "${FAT}/res/logo.bmp" "res logo old"
  put "${BL}/res/logo.bmp" "res logo new"
  put "${BL}/res/battery.bmp" "res battery new"
  put "${FAT}/extlinux/extlinux.conf" "LABEL ROCKNIX" "  LINUX /KERNEL" "  FDTDIR /"
  blob "${BL}/u-boot.bin" 1234567
}

test_s922x_runs_clean() {
  setup S922X
  s922x_files
  run_update
  assert_clean_run
}

test_s922x_uboot_at_sector_1() {
  setup S922X
  s922x_files
  run_update
  assert_eq "$(written_at 512 "${BL}/u-boot.bin")" u-boot.bin "u-boot at sector 1"
  check_disk 512:"${BL}/u-boot.bin"
}

test_s922x_boot_files() {
  setup S922X
  s922x_files
  run_update
  assert_same "${BL}/meson-g12b-odroid-go-ultra.dtb" "${FAT}/meson-g12b-odroid-go-ultra.dtb"
  assert_same "${BL}/meson-g12b-powkiddy-rgb10-max-3-pro.dtb" "${FAT}/meson-g12b-powkiddy-rgb10-max-3-pro.dtb"
  [ -e "${FAT}/meson-g12b-not-installed.dtb" ] && fail "dtb added that was not on the boot partition"
  assert_same "${BL}/overlays/panel.dtbo" "${FAT}/overlays/panel.dtbo"
  assert_same "${BL}/res/logo.bmp" "${FAT}/res/logo.bmp"
  assert_same "${BL}/res/battery.bmp" "${FAT}/res/battery.bmp"
}

H700_DT_ID=sun50i-h700-anbernic-rg35xx-h
H700_UBOOT=_u-boot-sunxi-with-spl.bin

h700_files() {
  local d
  for d in ${H700_DT_ID} sun50i-h700-anbernic-rg35xx-plus; do
    put "${FAT}/device_trees/${d}.dtb" "dtb ${d} old"
    put "${BL}/device_trees/${d}.dtb" "dtb ${d} new"
  done
  put "${FAT}/dtb.img" "dtb ${H700_DT_ID} old"
  put "${FAT}/overlays/user.dtbo" "dtbo user old"
  put "${BL}/overlays/sun50i-h700-anbernic-rg35xx-2024-ddr3.dtbo" "dtbo ddr3 new"
  put "${FAT}/extlinux/extlinux.conf" "LABEL ROCKNIX" "  LINUX /KERNEL" "  FDT /dtb.img" "  APPEND quiet"
  blob "${BL}/H700_DDR3${H700_UBOOT}" 800001
  blob "${BL}/H700_DDR4${H700_UBOOT}" 810003
  mkdir -p "${SYS}/firmware/devicetree/base"
  printf '%s\0' ${H700_DT_ID} >"${SYS}/firmware/devicetree/base/rocknix-dt-id"
  compatible anbernic,rg35xx-h allwinner,sun50i-h700
  regulator regulator.1 vcc-io 3300000
  [ -n "$1" ] && regulator regulator.5 vdd-dram "$1"
}

h700_uboot() {
  written_at 8192 "${BL}/H700_DDR3${H700_UBOOT}" "${BL}/H700_DDR4${H700_UBOOT}"
}

test_h700_runs_clean() {
  setup H700
  h700_files 1100000
  run_update
  assert_clean_run
}

test_h700_ddr3_uboot_at_8k() {
  setup H700
  h700_files 1200000
  run_update
  assert_eq "$(h700_uboot)" "H700_DDR3${H700_UBOOT}" "u-boot at 8 KiB"
  check_disk 8192:"${BL}/H700_DDR3${H700_UBOOT}"
}

test_h700_ddr4_uboot_at_8k() {
  setup H700
  h700_files 1100000
  run_update
  assert_eq "$(h700_uboot)" "H700_DDR4${H700_UBOOT}" "u-boot at 8 KiB"
  check_disk 8192:"${BL}/H700_DDR4${H700_UBOOT}"
}

test_h700_unknown_dram_keeps_uboot() {
  setup H700
  h700_files
  run_update
  check_disk
}

test_h700_boot_files() {
  setup H700
  h700_files 1100000
  run_update
  assert_same "${BL}/device_trees/${H700_DT_ID}.dtb" "${FAT}/device_trees/${H700_DT_ID}.dtb"
  assert_same "${BL}/device_trees/sun50i-h700-anbernic-rg35xx-plus.dtb" "${FAT}/device_trees/sun50i-h700-anbernic-rg35xx-plus.dtb"
  assert_same "${BL}/overlays/sun50i-h700-anbernic-rg35xx-2024-ddr3.dtbo" "${FAT}/overlays/sun50i-h700-anbernic-rg35xx-2024-ddr3.dtbo"
  assert_same "${BL}/device_trees/${H700_DT_ID}.dtb" "${FAT}/dtb.img"
}

amd64_files() {
  put "${FAT}/syslinux.cfg" "DEFAULT run"
  put "${FAT}/ldlinux.sys" "ldlinux"
  put "${FAT}/EFI/BOOT/bootx64.efi" "efi old"
  put "${FAT}/EFI/BOOT/grub.cfg" "grub old"
  put "${BL}/EFI/BOOT/bootx64.efi" "efi new"
}

test_amd64_runs_clean() {
  setup AMD64
  amd64_files
  run_update
  assert_clean_run
}

test_amd64_boot_files() {
  setup AMD64
  amd64_files
  run_update
  assert_same "${BL}/EFI/BOOT/bootx64.efi" "${FAT}/EFI/BOOT/bootx64.efi"
  assert_eq "$(cat "${FAT}/EFI/BOOT/grub.cfg")" "grub old" "grub.cfg"
  assert_eq "$(cat "${FAT}/syslinux.cfg")" "DEFAULT run" "syslinux.cfg"
  [ -e "${FAT}/update.sh" ] && fail "update.sh left on the boot partition"
  check_disk
}
