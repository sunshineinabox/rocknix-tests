# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

ROCKNIX_HWDB=${REPO}/projects/ROCKNIX/packages/sysutils/systemd/hwdb.d

filter_known() {
  if [ -s "$1" ]; then grep -vFf "$1"; else cat; fi
}

compile_hwdb() {
  mkdir -p hw/usr/lib/udev/hwdb.d
  cp /usr/lib/udev/hwdb.d/*.hwdb hw/usr/lib/udev/hwdb.d/
  cp "${ROCKNIX_HWDB}"/*.hwdb hw/usr/lib/udev/hwdb.d/
  systemd-hwdb update --strict --root=hw --usr
}

ordering_cycles() {
  awk '/Found ordering cycle on/ { split("", units); found = 1 }
       found && /Found (ordering cycle|dependency) on/ { unit = $NF; sub(/\/.*/, "", unit); units[unit] = 1 }
       found && /deleted to break ordering cycle/ { line = ""; for (unit in units) line = line " " unit; print line; found = 0 }' |
    while read -r line; do echo "cycle $(printf '%s\n' ${line} | sort | tr '\n' ' ')"; done | sed 's/ $//' | sort -u
}

test_units_verify() {
  local units out
  cd /usr/lib/systemd/system
  units=$(ls *.service *.socket *.timer *.path *.mount *.target 2>/dev/null | grep -v '@' | grep -v '^breakpoint-')
  out=$(systemd-analyze verify --man=no ${units} 2>&1)
  out=$({ echo "${out}" | grep -v 'ordering cycle\|Found dependency on'; echo "${out}" | ordering_cycles; } |
    filter_known "${TESTS}/userspace/units.known")
  [ -z "${out}" ] || fail "${out}"
}

test_udev_rules_verify() {
  local rules out
  rules=$(find "${REPO}/projects/ROCKNIX" -path '*udev*' -name '*.rules')
  out=$(udevadm verify --resolve-names=late /usr/lib/udev/rules.d/*.rules ${rules} 2>&1 |
    grep -E '^/' | grep -v 'udev rules check failed' | filter_known "${TESTS}/userspace/udev.known")
  [ -z "${out}" ] || fail "${out}"
}

test_hwdb_compiles() {
  compile_hwdb || fail "systemd-hwdb update --strict failed"
}

test_hwdb_ayaneo_air_power_key() {
  local dmi="dmi:bvnAYANEO:bvr1.0:bd01/01/2023:br1.0:svnAYANEO:pnAIRPro:pvr1.0:rvnAYANEO:rnAIRPro:rvr1.0:cvnAYANEO:ct10:cvr1.0:"
  compile_hwdb >/dev/null 2>&1 || fail "hwdb does not compile"
  assert_eq "$(systemd-hwdb query --root=hw "evdev:atkbd:${dmi}" | grep KEYBOARD_KEY_67)" "KEYBOARD_KEY_67=power" atkbd
  assert_eq "$(systemd-hwdb query --root=hw "evdev:name:AT Translated Set 2 keyboard:${dmi}" |
    grep KEYBOARD_KEY_67)" "KEYBOARD_KEY_67=power" "evdev:name lookup, imported last by 60-evdev.rules"
}

test_tmpfiles_parse() {
  local out
  out=$(systemd-tmpfiles --dry-run --create --boot 2>&1 | grep -iE 'failed to parse|unknown|invalid|syntax' |
    grep -v 'Failed to resolve specifier')
  [ -z "${out}" ] || fail "${out}"
}
