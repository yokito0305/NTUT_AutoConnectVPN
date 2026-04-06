#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OPENCONNECT_DIR="${REPO_ROOT}/third_party/openconnect"
OUTPUT_DIR="${1:-${REPO_ROOT}/out/openconnect-win64}"
STAGING_DIR="${OUTPUT_DIR}/bin"
BUILD_ROOT="${BUILD_ROOT:-$(mktemp -d)}"
BUILD_OPENCONNECT_DIR="${BUILD_ROOT}/openconnect"

cleanup() {
  rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT

if [[ ! -d "${OPENCONNECT_DIR}" ]]; then
  echo "OpenConnect submodule not found at ${OPENCONNECT_DIR}" >&2
  exit 1
fi

if ! command -v mingw64-configure >/dev/null 2>&1; then
  echo "mingw64-configure is required. Use the Fedora-based toolchain described in third_party/openconnect-build/README.md" >&2
  exit 1
fi

rm -rf "${OUTPUT_DIR}"
mkdir -p "${STAGING_DIR}"
rm -rf "${BUILD_OPENCONNECT_DIR}"
mkdir -p "${BUILD_ROOT}"

cp -a "${OPENCONNECT_DIR}" "${BUILD_OPENCONNECT_DIR}"

find "${BUILD_OPENCONNECT_DIR}" -type f \
  \( -name '*.sh' -o -name '*.ac' -o -name '*.am' -o -name '*.m4' -o -name '*.in' \
     -o -name '*.c' -o -name '*.h' -o -name 'configure' \) \
  -exec sed -i 's/\r$//' {} +

pushd "${BUILD_OPENCONNECT_DIR}" >/dev/null
./autogen.sh
find . -type f \( -name 'configure' -o -name 'libtool' \) -exec sed -i 's/\r$//' {} +
mingw64-configure \
  --with-vpnc-script=vpnc-script-win.js \
  --without-gnutls-version-check \
  --disable-nls \
  --disable-dsa-tests \
  --sbindir='${exec_prefix}/bin' \
  CFLAGS=-g
find . -type f \( -name 'config.status' -o -name 'libtool' -o -name 'Makefile' \) -exec sed -i 's/\r$//' {} +
make -j"$(getconf _NPROCESSORS_ONLN)"
popd >/dev/null

"${SCRIPT_DIR}/stage-openconnect-runtime.sh" "${BUILD_OPENCONNECT_DIR}" "${STAGING_DIR}"

cat > "${OUTPUT_DIR}/MANIFEST.txt" <<EOF
Source-Submodule: third_party/openconnect
Build-Type: MinGW64/GnuTLS
Output-Directory: ${OUTPUT_DIR}
EOF

echo "Staged OpenConnect runtime at ${OUTPUT_DIR}"
