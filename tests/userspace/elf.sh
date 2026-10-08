# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

ELFCHECK=${TESTS}/lib/elfcheck.py
ELF_KNOWN=${TESTS}/userspace/elf.known
ELF_DIRS="/usr/bin /usr/sbin /usr/lib /usr/libexec /usr/lib32 /usr/share /usr/local /usr/config"
ELF_LD_LIBRARY_PATH="--ld-library-path /usr/lib/compat"
LD_PATH_SCRIPT_DIRS="/usr/bin /usr/sbin /usr/lib/rocknix /usr/lib/autostart /usr/config /etc/profile.d"

device_ld_cache() {
  [ -e /storage/.cache/ld.so.cache ] && return
  trap 'rm -f /storage/.cache/ld.so.cache' EXIT
  mkdir -p /storage/.cache && ldconfig >/dev/null 2>&1
}

test_shared_libraries_resolve() {
  local out
  out=$(python3 "${ELFCHECK}" --bits 64 ${ELF_LD_LIBRARY_PATH} --known "${ELF_KNOWN}" ${ELF_DIRS}) || fail "elfcheck.py failed"
  [ -z "${out}" ] || fail "64-bit libraries not found the way ld.so searches:"$'\n'"${out}"
}

test_lib32_shared_libraries_resolve() {
  local out
  [ -d /usr/lib32 ] || skip "no /usr/lib32 in this image"
  out=$(python3 "${ELFCHECK}" --bits 32 ${ELF_LD_LIBRARY_PATH} --known "${ELF_KNOWN}" ${ELF_DIRS}) || fail "elfcheck.py failed"
  [ -z "${out}" ] || fail "32-bit libraries not found the way ld.so searches:"$'\n'"${out}"
}

test_symbol_versions_resolve() {
  local out
  out=$(python3 "${ELFCHECK}" --versions ${ELF_LD_LIBRARY_PATH} --known "${ELF_KNOWN}" ${ELF_DIRS}) || fail "elfcheck.py failed"
  [ -z "${out}" ] || fail "symbol versions not provided by the library ld.so picks:"$'\n'"${out}"
}

test_ldconfig_cache_builds_cleanly() {
  local out
  command -v ldconfig >/dev/null || skip "no ldconfig in this image"
  out=$(ldconfig -X -C ld.so.cache 2>&1 >/dev/null | sed -E -e 's/^[^:]*ldconfig[^:]*: /ldconfig: /' \
    -e 's/libraries ([^ ]+)\.so[^ ]* and [^ ]+ in directory/libraries \1.so.* in directory/' | grep -vxF -f "${ELF_KNOWN}")
  [ -z "${out}" ] || fail "${out}"
}

test_ld_library_path_dirs_exist() {
  local file line value dir failures=""
  while IFS=: read -r file line value; do
    value=${value#*=}
    for dir in $(echo "${value#\"}" | tr ':' ' '); do
      [ -d "${dir}" ] || known_failure "${ELF_KNOWN}" "${file} ${dir}" ||
        failures="${failures}${file}:${line}: ${dir}"$'\n'
    done
  done < <(grep -rIno -E '(BOX(64|86)_)?LD_LIBRARY_PATH="?/usr/[^"$ ;]*' ${LD_PATH_SCRIPT_DIRS} 2>/dev/null)
  [ -z "${failures}" ] || fail "LD_LIBRARY_PATH points at missing directories:"$'\n'"${failures}"
}

test_checker_reports_broken_copies() {
  local out
  mkdir missing version
  python3 - /usr/bin/bash <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
open("missing/bash", "wb").write(data.replace(b"\0libc.so.6\0", b"\0libZ.so.6\0", 1))
open("version/bash", "wb").write(data.replace(b"\0GLIBC_2.17\0", b"\0GLIBC_9.17\0", 1))
EOF
  chmod 755 missing/bash version/bash
  out=$(python3 "${ELFCHECK}" --bits 64 "${PWD}/missing" "${PWD}/version")
  assert_eq "${out}" "${PWD}/missing/bash: missing libZ.so.6" "missing library"
  out=$(python3 "${ELFCHECK}" --versions "${PWD}/missing" "${PWD}/version")
  assert_eq "${out}" "${PWD}/version/bash: libc.so.6 lacks GLIBC_9.17" "missing symbol version"
  out=$(python3 "${ELFCHECK}" --compare-ld-so "${PWD}/missing" "${PWD}/version")
  [ -z "${out}" ] || fail "ld.so sees the broken copies differently:"$'\n'"${out}"
}

test_executables_bind_all_symbols() {
  local out
  device_ld_cache
  out=$(python3 "${ELFCHECK}" --undefined --known "${ELF_KNOWN}" ${ELF_DIRS}) || fail "elfcheck.py failed"
  [ -z "${out}" ] || fail "undefined symbols when ld.so binds everything (LD_BIND_NOW=1):"$'\n'"${out}"
}

test_checker_matches_ld_so() {
  local out
  device_ld_cache
  out=$(python3 "${ELFCHECK}" --compare-ld-so ${ELF_DIRS}) || fail "elfcheck.py failed"
  [ -z "${out}" ] || fail "elfcheck.py and ld.so --list disagree:"$'\n'"${out}"
}

test_gconv_converts_common_charsets() {
  local out
  out=$(python3 - <<'PY'
import ctypes
libc = ctypes.CDLL(None)
libc.iconv_open.restype = ctypes.c_void_p
for charset in ("UTF-16LE", "UTF-16", "UTF-32", "ISO-8859-15", "CP1252", "SHIFT_JIS"):
    if libc.iconv_open(charset.encode(), b"UTF-8") in (None, ctypes.c_void_p(-1).value):
        print(charset)
PY
) || fail "python3 failed"
  [ -z "${out}" ] || fail "iconv_open from UTF-8 fails for:"$'\n'"${out}"
}
