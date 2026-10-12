#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

STAGE=$1
shift

mkdir -p /tmp/tree /tmp/skel /tmp/install "${STAGE}"
[ -f /dirs ] && (cd /tmp/skel && sed 's#^/##' /dirs | xargs -d '\n' mkdir -p)
cp -a /tmp/skel/. "${STAGE}/"
for d in config scripts packages projects distributions tools; do
  [ -e "/repo/${d}" ] && cp -a "/repo/${d}" /tmp/tree/
done
cd /tmp/tree

copy_dir() {
  [ -d "$1/$2" ] || return 0
  mkdir -p "${STAGE}/$3"
  cp -Pr "$1/$2"/$4 "${STAGE}/$3/" 2>/dev/null
}

for PKG in "$@"; do
  (
    . config/options "${PKG}" >/dev/null 2>&1 || exit 0
    set +e
    trap - ERR
    die() { echo "$1" >&2; }
    INSTALL=/tmp/install/${PKG_NAME}
    PKG_BUILD=/nonexistent
    dirs=()
    for dir in "${PKG_DIR}" "${PROJECT_DIR}/${PROJECT}/packages/${PKG_NAME}" \
      "${PROJECT_DIR}/${PROJECT}/devices/${DEVICE}/packages/${PKG_NAME}"; do
      [ -d "${dir}" ] && dirs+=("${dir}")
    done
    units=$(for dir in "${dirs[@]}"; do ls "${dir}/system.d" 2>/dev/null; done | grep -E '\.(service|socket|timer|path)$')
    if [ -n "${units}" ] && [ -f /units ] && ! grep -qxF -f <(echo "${units}") /units; then
      echo "${PKG} (not in this image, skipped)"
      exit 0
    fi
    cp -a /tmp/skel "${INSTALL}"
    for f in pre_makeinstall_target makeinstall_target post_makeinstall_target; do
      declare -F "${f}" >/dev/null && "${f}" >/dev/null 2>&1
    done
    for dir in "${dirs[@]}"; do
      copy_dir "${dir}" profile.d etc/profile.d '*'
      copy_dir "${dir}" tmpfiles.d usr/lib/tmpfiles.d '*.conf'
      copy_dir "${dir}" autostart usr/lib/autostart/common '*'
      copy_dir "${dir}" daemons usr/lib/autostart/daemons '*'
      copy_dir "${dir}" system.d usr/lib/systemd/system '*.*'
      copy_dir "${dir}" udev.d usr/lib/udev/rules.d '*.rules'
      copy_dir "${dir}" hwdb.d usr/lib/udev/hwdb.d '*.hwdb'
      copy_dir "${dir}" sleep.d usr/lib/systemd/system-sleep '*'
      copy_dir "${dir}" sleep.d.serial usr/lib/systemd/system-sleep.serial '*'
      copy_dir "${dir}" sysctl.d usr/lib/sysctl.d '*.conf'
      copy_dir "${dir}" modules-load.d usr/lib/modules-load.d '*.conf'
      copy_dir "${dir}" sysconf.d etc/sysconf.d '*.conf'
      copy_dir "${dir}" debug.d usr/share/debugconf '*.conf'
      copy_dir "${dir}" modprobe.d usr/lib/modprobe.d '*.conf'
    done
    chmod 0755 "${STAGE}"/usr/lib/autostart/common/* 2>/dev/null
    cp -a "${INSTALL}/." "${STAGE}/"
    INSTALL=${STAGE}
    declare -F post_install >/dev/null && post_install >/dev/null 2>&1
    echo "${PKG}"
  )
done

cd "${STAGE}"
rm -rf etc/passwd etc/group etc/shadow etc/gshadow usr/cache usr/include usr/lib/pkgconfig
find . -type d -empty -delete
