#!/usr/bin/env bash
set -euo pipefail

OPENCONNECT_DIR="${1:?usage: stage-openconnect-runtime.sh <openconnect-dir> <staging-dir>}"
STAGING_DIR="${2:?usage: stage-openconnect-runtime.sh <openconnect-dir> <staging-dir>}"
MINGW_BINDIR="${MINGW_BINDIR:-/usr/x86_64-w64-mingw32/sys-root/mingw/bin}"

mkdir -p "${STAGING_DIR}"

copy_if_exists() {
  local source_path="$1"
  if [[ -f "${source_path}" ]]; then
    cp -f "${source_path}" "${STAGING_DIR}/"
  fi
}

copy_first_existing() {
  local source_path
  for source_path in "$@"; do
    if [[ -f "${source_path}" ]]; then
      cp -f "${source_path}" "${STAGING_DIR}/"
      return 0
    fi
  done
  return 1
}

copy_first_existing "${OPENCONNECT_DIR}/.libs/openconnect.exe" "${OPENCONNECT_DIR}/openconnect.exe"
copy_first_existing "${OPENCONNECT_DIR}/.libs/list-system-keys.exe" "${OPENCONNECT_DIR}/list-system-keys.exe"
copy_if_exists "${OPENCONNECT_DIR}/.libs/wintun.dll"
copy_first_existing "${OPENCONNECT_DIR}/.libs/libopenconnect-5.dll" "${MINGW_BINDIR}/libopenconnect-5.dll"
copy_if_exists "${OPENCONNECT_DIR}/COPYING.LGPL"

mapfile -t roots < <(printf '%s\n' \
  "${STAGING_DIR}/openconnect.exe" \
  "${STAGING_DIR}/list-system-keys.exe" \
  "${STAGING_DIR}/libopenconnect-5.dll")

declare -A visited=()
queue=()

for root in "${roots[@]}"; do
  if [[ -f "${root}" ]]; then
    visited["$(basename "${root}")"]=1
    queue+=("${root}")
  fi
done

while [[ "${#queue[@]}" -gt 0 ]]; do
  current="${queue[0]}"
  queue=("${queue[@]:1}")

  while IFS= read -r dll_name; do
    [[ -n "${dll_name}" ]] || continue
    if [[ -n "${visited[${dll_name}]+x}" ]]; then
      continue
    fi
    visited["${dll_name}"]=1

    source_path="${MINGW_BINDIR}/${dll_name}"
    if [[ -f "${source_path}" ]]; then
      cp -f "${source_path}" "${STAGING_DIR}/"
      queue+=("${STAGING_DIR}/${dll_name}")
    fi
  done < <(x86_64-w64-mingw32-objdump -p "${current}" | sed -n 's/.*DLL Name: //p')
done

echo "Staged files:"
find "${STAGING_DIR}" -maxdepth 1 -type f | sort
