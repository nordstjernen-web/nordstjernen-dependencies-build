#!/usr/bin/env bash
# Shared helpers for cross-compiling the Nordstjernen Android dependency
# sysroot. Sourced by gen-cross-files.sh and build-android-deps.sh.
#
# Conventions:
#   ABI       one of: arm64-v8a armeabi-v7a x86_64 x86
#   API       Android API level / minSdk (default 35)
#   NDK r27   toolchains/llvm/prebuilt/<host>/bin
#
# Every link step must pass -Wl,-z,max-page-size=16384 (16 KB pages, required
# by Google Play). That flag is injected into the meson cross-files, the CMake
# linker flag variables and the autotools LDFLAGS below.

set -euo pipefail

if [ "${NORDSTJERNEN_ANDROID_VERBOSE:-0}" != "0" ]; then
  set -x
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ALL_ABIS=(arm64-v8a armeabi-v7a x86_64 x86)
ANDROID_API="${ANDROID_API:-35}"
NDK_VERSION_EXPECTED="27.3.13750724"
PAGE_SIZE_LDFLAG="-Wl,-z,max-page-size=16384"
# Bionic has no _init/_fini, but many GNU-style version scripts localize them;
# the NDK links with --no-undefined-version --fatal-warnings, turning that into
# a hard error (seen with pcre2 et al.). Re-allow undefined version-script
# symbols -- the last of the two flags wins in lld.
UNDEF_VER_LDFLAG="-Wl,--undefined-version"
# Flags applied to every link step (CMake / Meson / Autotools / OpenSSL).
LINK_LDFLAGS="${PAGE_SIZE_LDFLAG} ${UNDEF_VER_LDFLAG}"

# Repository layout (this file lives in android/scripts/lib/).
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "${COMMON_SH_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${ANDROID_DIR}/.." && pwd)"
MANIFEST_FILE="${ANDROID_DIR}/deps/manifest.txt"
CROSS_DIR="${ANDROID_DIR}/cross"

log()  { printf '\033[1;34m[deps]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[deps] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deps] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# NDK discovery
# ---------------------------------------------------------------------------
detect_host_tag() {
  case "$(uname -s)" in
    Linux)  echo "linux-x86_64" ;;
    Darwin) echo "darwin-x86_64" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows-x86_64" ;;
    *) die "unsupported build host: $(uname -s)" ;;
  esac
}

require_ndk() {
  : "${ANDROID_NDK_HOME:=${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
  [ -n "${ANDROID_NDK_HOME}" ] || die "ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) is not set"
  [ -d "${ANDROID_NDK_HOME}" ] || die "NDK directory not found: ${ANDROID_NDK_HOME}"

  HOST_TAG="$(detect_host_tag)"
  NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}"
  NDK_BIN="${NDK_TOOLCHAIN}/bin"
  NDK_CMAKE_TOOLCHAIN="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
  [ -d "${NDK_BIN}" ] || die "NDK toolchain bin not found: ${NDK_BIN}"
  [ -f "${NDK_CMAKE_TOOLCHAIN}" ] || die "NDK cmake toolchain not found: ${NDK_CMAKE_TOOLCHAIN}"

  # Soft version check: warn rather than fail so a compatible r27.x still works.
  local rel="${ANDROID_NDK_HOME}/source.properties"
  if [ -f "${rel}" ]; then
    local v
    v="$(sed -n 's/^Pkg.Revision *= *//p' "${rel}" | tr -d '[:space:]')"
    [ "${v}" = "${NDK_VERSION_EXPECTED}" ] || \
      warn "NDK ${v} != pinned ${NDK_VERSION_EXPECTED}; continuing anyway"
  fi
  log "Using NDK ${ANDROID_NDK_HOME} (host ${HOST_TAG}, API ${ANDROID_API})"
}

log_tool_versions() {
  local tool
  log "Build host: $(uname -a)"
  for tool in bash meson ninja cmake pkg-config python3 autoconf automake libtool gperf make curl tar sha256sum; do
    if command -v "${tool}" >/dev/null 2>&1; then
      log "tool ${tool}: $(command -v "${tool}")"
      case "${tool}" in
        meson|ninja|cmake|pkg-config|python3|autoconf|automake|gperf|make|curl|tar)
          "${tool}" --version 2>&1 | head -3 | sed 's/^/[deps]   /' >&2 || true
          ;;
      esac
    else
      warn "tool ${tool}: missing"
    fi
  done
}

# ---------------------------------------------------------------------------
# Per-ABI environment
#
# Sets, for the given ABI: ABI_TRIPLE (binutils prefix), ABI_CLANG_TRIPLE
# (clang driver prefix incl. API), ABI_CPU_FAMILY/ABI_CPU/ABI_ENDIAN (meson),
# ABI_OPENSSL_TARGET, plus CC/CXX/AR/RANLIB/STRIP/LD pointing at the NDK.
# ---------------------------------------------------------------------------
set_abi_env() {
  local abi="$1"
  case "${abi}" in
    arm64-v8a)
      ABI_TRIPLE="aarch64-linux-android"
      ABI_CLANG_TRIPLE="aarch64-linux-android${ANDROID_API}"
      ABI_CPU_FAMILY="aarch64"; ABI_CPU="aarch64"
      ABI_OPENSSL_TARGET="android-arm64" ;;
    armeabi-v7a)
      ABI_TRIPLE="arm-linux-androideabi"
      ABI_CLANG_TRIPLE="armv7a-linux-androideabi${ANDROID_API}"
      ABI_CPU_FAMILY="arm"; ABI_CPU="armv7a"
      ABI_OPENSSL_TARGET="android-arm" ;;
    x86_64)
      ABI_TRIPLE="x86_64-linux-android"
      ABI_CLANG_TRIPLE="x86_64-linux-android${ANDROID_API}"
      ABI_CPU_FAMILY="x86_64"; ABI_CPU="x86_64"
      ABI_OPENSSL_TARGET="android-x86_64" ;;
    x86)
      ABI_TRIPLE="i686-linux-android"
      ABI_CLANG_TRIPLE="i686-linux-android${ANDROID_API}"
      ABI_CPU_FAMILY="x86"; ABI_CPU="i686"
      ABI_OPENSSL_TARGET="android-x86" ;;
    *) die "unknown ABI: ${abi}" ;;
  esac
  ABI_ENDIAN="little"

  CC="${NDK_BIN}/${ABI_CLANG_TRIPLE}-clang"
  CXX="${NDK_BIN}/${ABI_CLANG_TRIPLE}-clang++"
  AR="${NDK_BIN}/llvm-ar"
  RANLIB="${NDK_BIN}/llvm-ranlib"
  STRIP="${NDK_BIN}/llvm-strip"
  LD="${NDK_BIN}/ld.lld"
  NM="${NDK_BIN}/llvm-nm"
  [ -x "${CC}" ] || die "clang driver not found for ${abi}: ${CC}"
  export CC CXX AR RANLIB STRIP NM
}

is_valid_abi() {
  local a
  for a in "${ALL_ABIS[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
declare -A DEP_VERSION DEP_SHA256 DEP_URL
DEP_ORDER=()

load_manifest() {
  [ -f "${MANIFEST_FILE}" ] || die "manifest not found: ${MANIFEST_FILE}"
  local name version sha url
  while read -r name version sha url _; do
    [ -z "${name}" ] && continue
    case "${name}" in \#*) continue ;; esac
    DEP_VERSION["${name}"]="${version}"
    DEP_SHA256["${name}"]="${sha}"
    DEP_URL["${name}"]="${url}"
    DEP_ORDER+=("${name}")
  done < "${MANIFEST_FILE}"
  [ "${#DEP_ORDER[@]}" -gt 0 ] || die "manifest is empty: ${MANIFEST_FILE}"
}

# ---------------------------------------------------------------------------
# Download + verify + extract
#
# Tarballs are cached under ${TARBALL_CACHE} (default android/.cache/tarballs)
# and re-verified on every run. The cache filename is prefixed with the
# dependency name so two deps that share a generic archive basename (e.g. the
# GitHub "archive/refs/tags/v1.2.0.tar.gz" form) can never collide.
# ---------------------------------------------------------------------------
TARBALL_CACHE="${TARBALL_CACHE:-${ANDROID_DIR}/.cache/tarballs}"

# Echo the cache path for a dependency's tarball (no I/O).
tarball_path() {
  local name="$1"; local url="${DEP_URL[$name]:-}"
  [ -n "${url}" ] || die "no manifest entry for '${name}'"
  printf '%s/%s-%s' "${TARBALL_CACHE}" "${name}" "$(basename "${url}")"
}

# Ensure a dependency's tarball is present in the cache and matches its sha256,
# downloading it if missing/corrupt. Idempotent and safe to run in parallel
# (each dep writes a distinct file). Does NOT extract.
download_verify() {
  local name="$1"
  local url="${DEP_URL[$name]:-}"; local sha="${DEP_SHA256[$name]:-}"
  [ -n "${url}" ] || die "no manifest entry for '${name}'"
  mkdir -p "${TARBALL_CACHE}"
  local file; file="$(tarball_path "${name}")"

  if [ ! -f "${file}" ] || ! echo "${sha}  ${file}" | sha256sum -c - >/dev/null 2>&1; then
    log "Downloading ${name} ${DEP_VERSION[$name]} from ${url}"
    # A real User-Agent avoids 4xx from picky upstreams (some reject curl's
    # default UA). --retry-all-errors retries non-transient HTTP codes too
    # (e.g. freedesktop.org intermittently 418s under parallel load), which
    # curl's plain --retry would otherwise not retry. Fail loudly here so a
    # download error is not later misreported as a checksum mismatch.
    if ! curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
              -A "nordstjernen-android-deps/1.0 (+https://github.com/nordstjernen-web/nordstjernen-android)" \
              -o "${file}.tmp" "${url}"; then
      rm -f "${file}.tmp"
      die "download failed for ${name} from ${url}"
    fi
    mv "${file}.tmp" "${file}"
  fi
  echo "${sha}  ${file}" | sha256sum -c - >/dev/null 2>&1 \
    || die "checksum mismatch for ${name} (${file}); delete it and re-run, or fix the manifest"
}

# Download every (or the named) dependency tarball up front, a few at a time.
# Overlapping the downloads -- instead of fetching one right before each serial
# build step -- shaves real wall-clock time off a cold build without relying on
# any CI cache being warm. Subsequent fetch_source calls become local hits.
_prefetch_batch() {
  local n p rc=0 pids=()
  for n in "$@"; do download_verify "${n}" & pids+=("$!"); done
  for p in "${pids[@]}"; do wait "${p}" || rc=1; done
  return "${rc}"
}

prefetch_sources() {
  local names=("$@"); [ "${#names[@]}" -eq 0 ] && names=("${DEP_ORDER[@]}")
  local maxjobs="${PREFETCH_JOBS:-4}"
  log "Prefetching ${#names[@]} source tarball(s), ${maxjobs} at a time"
  local rc=0 batch=() n
  for n in "${names[@]}"; do
    batch+=("${n}")
    if [ "${#batch[@]}" -ge "${maxjobs}" ]; then
      _prefetch_batch "${batch[@]}" || rc=1
      batch=()
    fi
  done
  [ "${#batch[@]}" -gt 0 ] && { _prefetch_batch "${batch[@]}" || rc=1; }
  [ "${rc}" -eq 0 ] || die "one or more source downloads failed during prefetch"
}

# Usage: fetch_source <name>  -> echoes the extracted source directory.
# Reuses the prefetched/cached tarball (downloading on demand if missing).
fetch_source() {
  local name="$1"
  download_verify "${name}"
  local file; file="$(tarball_path "${name}")"

  local dest="${BUILD_ROOT}/src/${name}"
  rm -rf "${dest}"; mkdir -p "${dest}"
  case "${file}" in
    *.tar.gz|*.tgz)  tar -xzf "${file}" -C "${dest}" --strip-components=1 ;;
    *.tar.bz2)       tar -xjf "${file}" -C "${dest}" --strip-components=1 ;;
    *.tar.xz)        tar -xJf "${file}" -C "${dest}" --strip-components=1 ;;
    *) die "unsupported archive type: ${file}" ;;
  esac
  echo "${dest}"
}

# ---------------------------------------------------------------------------
# pkg-config / build environment shared by every dependency
# ---------------------------------------------------------------------------
setup_build_env() {
  # All deps install with an absolute prefix, so .pc files carry absolute
  # paths; do NOT set a pkg-config sysroot or paths would be double-prefixed.
  export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
  unset PKG_CONFIG_SYSROOT_DIR || true
  export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"

  # ccache speeds up reruns when CMAKE/AUTOTOOLS share objects.
  if command -v ccache >/dev/null 2>&1 && [ "${HOST_TAG:-}" != "windows-x86_64" ]; then
    export CCACHE_DIR="${CCACHE_DIR:-${ANDROID_DIR}/.cache/ccache}"
    mkdir -p "${CCACHE_DIR}"
    CC_LAUNCHER="ccache"
  else
    CC_LAUNCHER=""
  fi
}

# ---------------------------------------------------------------------------
# Build-system wrappers. Each builds out-of-tree and installs into ${PREFIX}.
# ---------------------------------------------------------------------------
NPROC="$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) )"

build_cmake() {  # build_cmake <srcdir> [extra -D args...]
  local src="$1"; shift
  local b="${src}/_build"
  rm -rf "${b}"
  log "cmake source=${src} build=${b} prefix=${PREFIX}"
  local launcher=()
  [ -n "${CC_LAUNCHER}" ] && launcher=(-DCMAKE_C_COMPILER_LAUNCHER="${CC_LAUNCHER}" -DCMAKE_CXX_COMPILER_LAUNCHER="${CC_LAUNCHER}")
  cmake -G Ninja -S "${src}" -B "${b}" \
    -DCMAKE_TOOLCHAIN_FILE="${NDK_CMAKE_TOOLCHAIN}" \
    -DANDROID_ABI="${CURRENT_ABI}" \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="${LINK_LDFLAGS}" \
    -DCMAKE_MODULE_LINKER_FLAGS="${LINK_LDFLAGS}" \
    -DCMAKE_EXE_LINKER_FLAGS="${LINK_LDFLAGS}" \
    "${launcher[@]}" \
    "$@"
  cmake --build "${b}" --parallel "${NPROC}"
  cmake --install "${b}"
}

build_meson() {  # build_meson <srcdir> [extra -D args...]
  local src="$1"; shift
  local b="${src}/_build"
  rm -rf "${b}"
  log "meson source=${src} build=${b} prefix=${PREFIX}"
  meson setup "${b}" "${src}" \
    --cross-file "${CROSS_DIR}/${CURRENT_ABI}.cross" \
    --prefix "${PREFIX}" \
    --libdir lib \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Dpkg_config_path="${PREFIX}/lib/pkgconfig" \
    "$@"
  meson compile -C "${b}"
  meson install -C "${b}"
}

build_autotools() {  # build_autotools <srcdir> [extra ./configure args...]
  local src="$1"; shift
  log "autotools source=${src} prefix=${PREFIX}"
  ( cd "${src}"
    CC="${CC_LAUNCHER:+${CC_LAUNCHER} }${CC}" \
    CXX="${CC_LAUNCHER:+${CC_LAUNCHER} }${CXX}" \
    CFLAGS="${CFLAGS:-} -fPIC -O2 -DANDROID" \
    CXXFLAGS="${CXXFLAGS:-} -fPIC -O2 -DANDROID" \
    LDFLAGS="${LDFLAGS:-} ${LINK_LDFLAGS}" \
    ./configure \
      --host="${ABI_TRIPLE}" \
      --prefix="${PREFIX}" \
      --libdir="${PREFIX}/lib" \
      --enable-shared --disable-static \
      "$@"
    make -j"${NPROC}"
    make install
  )
}

# Strip installed shared libraries to keep the artifact small.
strip_install() {
  find "${PREFIX}/lib" -name '*.so*' -type f -print0 2>/dev/null \
    | xargs -0 -r -n1 "${STRIP}" --strip-unneeded 2>/dev/null || true
}
