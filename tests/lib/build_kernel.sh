#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

set -e

TARBALL=$1
FRAGMENT=$2
OUT=$3

export ARCH=arm64
[ "$(uname -m)" = aarch64 ] || export CROSS_COMPILE=aarch64-linux-gnu-

mkdir -p /tmp/linux
tar -xf "${TARBALL}" -C /tmp/linux --strip-components=1
cd /tmp/linux
make -s defconfig
scripts/kconfig/merge_config.sh -m .config "${FRAGMENT}" >/dev/null
make -s olddefconfig
for opt in $(sed -n 's/^\(CONFIG_[A-Z0-9_]*\)=y$/\1/p' "${FRAGMENT}"); do
  grep -qx "${opt}=y" .config || { echo "build_kernel: ${opt} is not =y after olddefconfig" >&2; exit 1; }
done
make -s -j"$(nproc)" Image
cp arch/arm64/boot/Image "${OUT}"
