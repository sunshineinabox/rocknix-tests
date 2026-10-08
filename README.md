# rocknix-tests

Tests for [ROCKNIX](https://github.com/ROCKNIX/distribution) images: the scripts in each image's
userspace, updating from an older release, every device's bootloader update, a QEMU boot with a
screenshot, and shellcheck on changed lines.

Clone it next to your distribution checkout:

```
git clone https://github.com/sunshineinabox/rocknix-tests
cd rocknix-tests
scripts/test fetch SM8250 nightly
scripts/test prepare ROCKNIX-SM8250.*.tar
scripts/test run rocknix-rootfs:SM8250-<version>
```

More in [tests/README.md](tests/README.md). The layout (`tests/`, `scripts/test`) matches the
distribution tree, so this can be dropped into it as is.
