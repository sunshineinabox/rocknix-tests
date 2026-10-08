# Tests

The harness runs ROCKNIX images in containers and in QEMU. All you need is Docker. Arm64 images run
natively on an arm64 machine and through qemu-user anywhere else.

## Quick start

```
scripts/test fetch SM8250 nightly                       # newest nightly update tar (needs gh)
scripts/test prepare ROCKNIX-SM8250.aarch64-20261010.tar
scripts/test run rocknix-rootfs:SM8250-20261010         # every suite
scripts/test run rocknix-rootfs:SM8250-20261010 busybox # one suite
```

`prepare` takes an update tar, a disk image or a bare SYSTEM file and imports it into Docker.
`fetch SM8250 nightly . img` downloads the nightly's disk image instead of the tar.

The tests check a distribution checkout against the binaries in the image. That's `../distribution`
unless you set `TEST_REPO`, and it's mounted read-only at `/repo`.

## Testing a branch without building it

```
TEST_REPO=../my-branch scripts/test run --overlay next rocknix-rootfs:SM8250-20261010
```

`--overlay` finds the packages that changed since `next`, runs their install steps in the
`rocknix-build` image and copies the result over the image before the tests start. That's enough
for scripts and config files. Anything that needs compiling still needs a real build, and files a
branch deletes stay in the image.

## Writing tests

A suite is a bash file in `tests/userspace/` (or `tests/update/`) with `test_*` functions. Each test
runs in its own subshell and scratch directory. The helpers are `fail`, `skip`, `assert_eq`,
`assert_contains`, and `stub <path>` / `unstub <path>` to swap out a binary for one test (undo it in
an `EXIT` trap). Put `# privileged` on its own line if the suite needs to mount over `/sys` or
`/dev`. `TEST_FILTER=<regex>` picks tests by `suite:name`.

Known problems are listed so they don't hide new ones:

- `tests/xfail` lists tests that fail because of a real bug in the tree. They show up as expected
  failures, and once the bug is fixed the runner says so.
- `*.known` files list output a test may ignore, one line each.

## Update path

```
scripts/test update rocknix-initramfs:SM8250-20260928 rocknix-rootfs:SM8250-20261010
```

This runs `update.sh`, `updateabl` and every device's bootloader `update.sh` the way `init` does
during an update: from the old release's initramfs, with the new system mounted at `/update`,
against a loop-backed disk. `prepare` imports each image's initramfs as
`rocknix-initramfs:<device>-<version>` for this.

## Booting in QEMU

```
scripts/test kernel linux-7.2.tar.xz       # once, builds the test kernel
scripts/test boot ROCKNIX-SM8250.aarch64-20261010.img.gz
scripts/test boot --display ROCKNIX-SM8250.aarch64-20261010.img.gz
```

The image boots on `qemu-system-aarch64 -M virt` with a generic kernel (mainline `defconfig` plus
`tests/boot/virt-arm64.config`) and the image's own initramfs. A oneshot unit waits for startup to
finish, reports failed units and shell errors from the journal and `/var/log/boot.log`, then powers
off. Things that can't work in a VM go in `tests/boot/units.known` and `errors.known` (`*` matches
anything), real bugs in the matching `.xfail` files.

`--display` also starts the compositor and EmulationStation on Mesa's software renderer and saves a
screenshot next to the serial log (`BOOT_LOG`, `/tmp/rocknix-boot.log` by default).

## Shellcheck

```
scripts/test lint next     # lines changed since next
scripts/test lint --all
```

`init`, `functions` and the bootloader `update.sh` scripts are checked as busybox ash, everything
else as bash.

## CI

`.github/workflows/test.yml` runs every evening at 17:00 UTC against the newest nightly of every
device, and on demand for a PR or ref of the distribution repo.

- Changes to scripts and configs only are overlaid on the nightly (`tests/lib/classify.py` decides).
  These jobs run on arm64 runners and also boot the nightly's disk image.
- Anything else is built from the nightly's build state and ccache, then tested and booted. That
  needs a `DISTRIBUTION_TOKEN` secret that can read the distribution repo's Actions artifacts.
- Changes to the bootloader, `updateabl`, busybox, glibc, util-linux or parted also run the update
  path.
- Each device job adds its results to the run summary and keeps its logs and screenshot as the
  `results-<device>` artifact. The last job puts all devices in one table.

Set the repository variable `SCHEDULED_DEVICES` to test fewer devices in the evening run.
