FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates cpio e2fsprogs fdisk flex kmod libelf-dev libssl-dev \
      mtools python3 qemu-system-arm qemu-utils xz-utils zstd \
 && if [ "$(dpkg --print-architecture)" != arm64 ]; then \
      apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu; \
    fi \
 && rm -rf /var/lib/apt/lists/*
