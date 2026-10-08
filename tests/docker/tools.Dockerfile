FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      binutils ca-certificates cpio fdisk gdisk gzip lz4 lzop mtools python3 shellcheck squashfs-tools xz-utils zstd \
 && rm -rf /var/lib/apt/lists/*
