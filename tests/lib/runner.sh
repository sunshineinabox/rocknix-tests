#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

REPO=${REPO:-/repo}
TESTS=${TESTS:-/tests}
SKIP_RC=77

fail() { echo "$*" >&2; exit 1; }
skip() { echo "$*" >&2; exit ${SKIP_RC}; }

assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected [$2], got [$1]"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-assert_contains}: [$2] not in [$1]" ;;
  esac
}

known_failure() {
  grep -qxF -- "$2" "$1" 2>/dev/null
}

STUBS=/.stubs

stub() {
  if [ ! -e "${STUBS}/orig$1" ] && [ ! -e "${STUBS}/new$1" ]; then
    if [ -e "$1" ] || [ -L "$1" ]; then
      mkdir -p "$(dirname "${STUBS}/orig$1")" && mv "$1" "${STUBS}/orig$1"
    else
      mkdir -p "$(dirname "${STUBS}/new$1")" && touch "${STUBS}/new$1"
    fi
  fi
  mkdir -p "$(dirname "$1")"
  cat >"$1"
  chmod 755 "$1"
}

unstub() {
  for f in "$@"; do
    if [ -e "${STUBS}/orig${f}" ] || [ -L "${STUBS}/orig${f}" ]; then
      mv -f "${STUBS}/orig${f}" "${f}"
    elif [ -e "${STUBS}/new${f}" ]; then
      rm -f "${f}" "${STUBS}/new${f}"
    fi
  done
}

attach_loop() {
  local dev
  for _ in $(seq 20); do
    if dev=$(losetup -f) && [ -f "/sys/class/block/${dev#/dev/}/dev" ]; then
      [ -b "${dev}" ] || mknod "${dev}" b $(tr ':' ' ' <"/sys/class/block/${dev#/dev/}/dev")
      losetup -P "${dev}" "$1" 2>/dev/null && echo "${dev}" && return
    fi
    sleep 0.2
  done
  return 1
}

suite_tests() {
  local t name
  name=$(basename "$1" .sh)
  for t in $(grep -oE '^test_[A-Za-z0-9_]+' "$1"); do
    [ -z "${TEST_FILTER}" ] || echo "${name}:${t#test_}" | grep -qE -- "${TEST_FILTER}" || continue
    echo "${t}"
  done
}

N=0
PASS=0
FAIL=0
SKIPPED=0
XFAIL=0
FAILED=""
LOG=$(mktemp)
TOTAL=0
for SUITE in "$@"; do
  TOTAL=$((TOTAL + $(suite_tests "${SUITE}" | wc -l)))
done
echo "1..${TOTAL}"

S=0
for SUITE in "$@"; do
  S=$((S + 1))
  NAME=$(basename "${SUITE}" .sh)
  TESTS_IN_SUITE=$(suite_tests "${SUITE}")
  COUNT=$(echo "${TESTS_IN_SUITE}" | grep -c .)
  case ${COUNT} in
    0) ;;
    1) echo "# [${S}/$#] ${NAME}: test $((N + 1)) of ${TOTAL}" ;;
    *) echo "# [${S}/$#] ${NAME}: tests $((N + 1))-$((N + COUNT)) of ${TOTAL}" ;;
  esac
  for T in ${TESTS_IN_SUITE}; do
    N=$((N + 1))
    (
      cd "$(mktemp -d)"
      . "${SUITE}"
      "${T}"
    ) >"${LOG}" 2>&1
    RC=$?
    if [ ${RC} -ne ${SKIP_RC} ] && known_failure "${TESTS}/xfail" "${NAME} ${T#test_}"; then
      if [ ${RC} -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "ok ${N} - ${NAME}: ${T#test_} # TODO passes on this image, listed in tests/xfail"
      else
        XFAIL=$((XFAIL + 1))
        echo "not ok ${N} - ${NAME}: ${T#test_} # TODO expected failure"
        LC_ALL=C sed -e 's/[^[:print:]	]/?/g' -e 's/^/#   /' "${LOG}"
      fi
      continue
    fi
    case ${RC} in
      0)
        PASS=$((PASS + 1))
        echo "ok ${N} - ${NAME}: ${T#test_}"
        ;;
      ${SKIP_RC})
        SKIPPED=$((SKIPPED + 1))
        echo "ok ${N} - ${NAME}: ${T#test_} # SKIP $(tail -n 1 "${LOG}")"
        ;;
      *)
        FAIL=$((FAIL + 1))
        FAILED="${FAILED}#   ${NAME}: ${T#test_}"$'\n'
        echo "not ok ${N} - ${NAME}: ${T#test_}"
        LC_ALL=C sed -e 's/[^[:print:]	]/?/g' -e 's/^/#   /' "${LOG}"
        ;;
    esac
  done
done

rm -f "${LOG}"
[ -z "${FAILED}" ] || printf '# failed:\n%s' "${FAILED}"
echo "# pass ${PASS}, fail ${FAIL}, skip ${SKIPPED}, xfail ${XFAIL}"
[ ${FAIL} -eq 0 ]
