#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

STAGE=$1
shift

mkdir -p /tmp/tree "${STAGE}"
[ -f /dirs ] && (cd "${STAGE}" && sed 's#^/##' /dirs | xargs -d '\n' mkdir -p)
for d in config scripts packages projects distributions tools; do
  [ -e "/repo/${d}" ] && cp -a "/repo/${d}" /tmp/tree/
done
cd /tmp/tree

for PKG in "$@"; do
  (
    . config/options "${PKG}" >/dev/null 2>&1 || exit 0
    set +e
    trap - ERR
    die() { echo "$1" >&2; }
    INSTALL=${STAGE}
    PKG_BUILD=/nonexistent
    for f in pre_makeinstall_target makeinstall_target post_makeinstall_target post_install; do
      declare -F "${f}" >/dev/null && "${f}" >/dev/null 2>&1
    done
    echo "${PKG}"
  )
done

cd "${STAGE}"
rm -rf etc/passwd etc/group etc/shadow etc/gshadow usr/cache usr/include usr/lib/pkgconfig
find . -type d -empty -delete
