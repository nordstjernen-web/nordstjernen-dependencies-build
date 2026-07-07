#!/usr/bin/env bash
# Shared helpers for cross-compiling the Nordstjernen iOS dependency sysroot.
# Sourced by gen-cross-files.sh and build-ios-deps.sh.
#
# Conventions:
#   PLATFORM    one of: device simulator
#   device      SDK iphoneos        (arm64, -miphoneos-version-min=15.0)
#   simulator   SDK iphonesimulator (arm64, -mios-simulator-version-min=15.0)
#   TOOLCHAIN   Xcode clang, resolved through `xcrun --sdk <sdk> --find`
#
# Every dependency is built as a STATIC library (.a); bitcode is NOT emitted.
# All compile/link steps pass `-arch arm64 -isysroot "$SDKROOT" <min-version>
# -fPIC -O2`. There is no Android-style page-size or version-script link flag
# here -- those are ELF/bionic-specific and irrelevant to Mach-O.

set -euo pipefail

if [ "${NORDSTJERNEN_IOS_VERBOSE:-0}" != "0" ]; then
  set -x
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ALL_PLATFORMS=(device simulator)
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"

# Repository layout (this file lives in ios/scripts/lib/).
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${COMMON_SH_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${IOS_DIR}/.." && pwd)"
MANIFEST_FILE="${IOS_DIR}/deps/manifest.txt"
CROSS_DIR="${IOS_DIR}/cross"

log()  { printf '\033[1;34m[deps]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[deps] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deps] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# GNU coreutils' `sha256sum` is not present on a stock macOS; fall back to the
# system `shasum -a 256`, which understands the same `-c` check protocol and
# prints the identical "<hex>  <path>" line format.
if command -v sha256sum >/dev/null 2>&1; then
  sha256bin() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256bin() { shasum -a 256 "$@"; }
else
  sha256bin() { die "no sha256 tool found (install coreutils' sha256sum or use shasum)"; }
fi

# ---------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------
require_toolchain() {
  command -v xcrun        >/dev/null 2>&1 || die "xcrun not found; install Xcode and the command-line tools"
  command -v xcode-select >/dev/null 2>&1 || die "xcode-select not found; install Xcode"
  local dev
  dev="$(xcode-select --print-path 2>/dev/null || true)"
  [ -n "${dev}" ] || die "no active Xcode developer directory (run: sudo xcode-select --switch <Xcode.app>/Contents/Developer)"
  [ -d "${dev}" ] || die "Xcode developer directory not found: ${dev}"
  XCODE_DEVELOPER_DIR="${dev}"
  log "Using Xcode at ${XCODE_DEVELOPER_DIR} (iOS deployment target ${IOS_DEPLOYMENT_TARGET})"
}

log_tool_versions() {
  local tool
  log "Build host: $(uname -a)"
  if command -v xcodebuild >/dev/null 2>&1; then
    log "xcode: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  fi
  for tool in bash meson ninja cmake pkg-config python3 autoconf automake libtool gperf nasm make curl tar; do
    if command -v "${tool}" >/dev/null 2>&1; then
      log "tool ${tool}: $(command -v "${tool}")"
      case "${tool}" in
        meson|ninja|cmake|pkg-config|python3|autoconf|automake|gperf|nasm|make|curl|tar)
          "${tool}" --version 2>&1 | head -3 | sed 's/^/[deps]   /' >&2 || true
          ;;
      esac
    else
      warn "tool ${tool}: missing"
    fi
  done
}

# ---------------------------------------------------------------------------
# Per-platform environment
#
# Sets, for the given PLATFORM: PLATFORM_SDK (xcrun SDK name), PLATFORM_ARCH,
# PLATFORM_SUBSYSTEM (meson host_machine subsystem), PLATFORM_MIN_FLAG (the
# deployment-target flag), PLATFORM_OPENSSL_TARGET, PLATFORM_CPU_FAMILY/
# PLATFORM_CPU/PLATFORM_ENDIAN (meson), PLATFORM_ARCH_FLAGS (the shared
# -arch/-isysroot/min triplet), plus SDKROOT and CC/CXX/AR/RANLIB/STRIP/NM
# pointing at the Xcode toolchain via xcrun.
# ---------------------------------------------------------------------------
set_platform_env() {
  local platform="$1"
  case "${platform}" in
    device)
      PLATFORM_SDK="iphoneos"
      PLATFORM_ARCH="arm64"
      PLATFORM_SUBSYSTEM="ios"
      PLATFORM_MIN_FLAG="-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
      PLATFORM_OPENSSL_TARGET="ios64-cross" ;;
    simulator)
      PLATFORM_SDK="iphonesimulator"
      PLATFORM_ARCH="arm64"
      PLATFORM_SUBSYSTEM="ios-simulator"
      PLATFORM_MIN_FLAG="-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
      PLATFORM_OPENSSL_TARGET="iossimulator-xcrun" ;;
    *) die "unknown platform: ${platform}" ;;
  esac
  PLATFORM_CPU_FAMILY="aarch64"; PLATFORM_CPU="aarch64"; PLATFORM_ENDIAN="little"

  SDKROOT="$(xcrun --sdk "${PLATFORM_SDK}" --show-sdk-path 2>/dev/null || true)"
  [ -n "${SDKROOT}" ] || die "could not resolve SDK path for ${PLATFORM_SDK} (is that SDK installed?)"
  [ -d "${SDKROOT}" ] || die "SDK path does not exist: ${SDKROOT}"

  CC="$(xcrun --sdk "${PLATFORM_SDK}" --find clang)"
  CXX="$(xcrun --sdk "${PLATFORM_SDK}" --find clang++)"
  AR="$(xcrun --sdk "${PLATFORM_SDK}" --find ar)"
  RANLIB="$(xcrun --sdk "${PLATFORM_SDK}" --find ranlib)"
  STRIP="$(xcrun --sdk "${PLATFORM_SDK}" --find strip)"
  NM="$(xcrun --sdk "${PLATFORM_SDK}" --find nm)"
  [ -x "${CC}" ] || die "clang not found for ${platform}: ${CC}"

  PLATFORM_ARCH_FLAGS="-arch ${PLATFORM_ARCH} -isysroot ${SDKROOT} ${PLATFORM_MIN_FLAG}"
  export CC CXX AR RANLIB STRIP NM SDKROOT
}

is_valid_platform() {
  local p
  for p in "${ALL_PLATFORMS[@]}"; do [ "$p" = "$1" ] && return 0; done
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
# Tarballs are cached under ${TARBALL_CACHE} (default ios/.cache/tarballs) and
# re-verified on every run. The cache filename is prefixed with the dependency
# name so two deps that share a generic archive basename (e.g. the GitHub
# "archive/refs/tags/v1.2.0.tar.gz" form) can never collide.
# ---------------------------------------------------------------------------
TARBALL_CACHE="${TARBALL_CACHE:-${IOS_DIR}/.cache/tarballs}"

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

  if [ ! -f "${file}" ] || ! echo "${sha}  ${file}" | sha256bin -c - >/dev/null 2>&1; then
    log "Downloading ${name} ${DEP_VERSION[$name]} from ${url}"
    # A real User-Agent avoids 4xx from picky upstreams (some reject curl's
    # default UA). --retry-all-errors retries non-transient HTTP codes too
    # (e.g. freedesktop.org intermittently 418s under parallel load), which
    # curl's plain --retry would otherwise not retry. Fail loudly here so a
    # download error is not later misreported as a checksum mismatch.
    if ! curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
              -A "nordstjernen-ios-deps/1.0 (+https://github.com/nordstjernen-web/nordstjernen-android)" \
              -o "${file}.tmp" "${url}"; then
      rm -f "${file}.tmp"
      die "download failed for ${name} from ${url}"
    fi
    mv "${file}.tmp" "${file}"
  fi
  echo "${sha}  ${file}" | sha256bin -c - >/dev/null 2>&1 \
    || die "checksum mismatch for ${name} (${file}); delete it and re-run, or fix the manifest"
}

# Download every (or the named) dependency tarball up front, a few at a time.
# Overlapping the downloads -- instead of fetching one right before each serial
# build step -- shaves real wall-clock time off a cold build without relying on
# any CI cache being warm. Subsequent fetch_source calls become local hits.
#
# This is BEST-EFFORT: it is only a warm-up. Some upstreams (e.g. freedesktop.org
# 418s, SourceForge mirror redirects) get flaky under parallel load, so a failed
# prefetch must NOT fail the build -- the authoritative, retrying download still
# happens serially in fetch_source at build time. We therefore warn, never die.
_prefetch_batch() {
  local n p rc=0 pids=()
  # Each job runs in its own subshell (via &), so download_verify's die() only
  # exits that job; we collect the failure via wait instead of aborting.
  for n in "$@"; do download_verify "${n}" & pids+=("$!"); done
  for p in "${pids[@]}"; do wait "${p}" || rc=1; done
  return "${rc}"
}

prefetch_sources() {
  local names=("$@"); [ "${#names[@]}" -eq 0 ] && names=("${DEP_ORDER[@]}")
  local maxjobs="${PREFETCH_JOBS:-4}"
  log "Prefetching ${#names[@]} source tarball(s), ${maxjobs} at a time (best-effort)"
  local rc=0 batch=() n
  for n in "${names[@]}"; do
    batch+=("${n}")
    if [ "${#batch[@]}" -ge "${maxjobs}" ]; then
      _prefetch_batch "${batch[@]}" || rc=1
      batch=()
    fi
  done
  [ "${#batch[@]}" -gt 0 ] && { _prefetch_batch "${batch[@]}" || rc=1; }
  [ "${rc}" -eq 0 ] || warn "some tarballs failed to prefetch; they will be re-fetched (with retries) at build time"
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

  # ccache speeds up reruns when CMake/Autotools share objects.
  if command -v ccache >/dev/null 2>&1; then
    export CCACHE_DIR="${CCACHE_DIR:-${IOS_DIR}/.cache/ccache}"
    mkdir -p "${CCACHE_DIR}"
    CC_LAUNCHER="ccache"
  else
    CC_LAUNCHER=""
  fi
}

# ---------------------------------------------------------------------------
# Build-system wrappers. Each builds out-of-tree, targets the iOS SDK, produces
# STATIC libraries, and installs into ${PREFIX}.
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
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES="${PLATFORM_ARCH}" \
    -DCMAKE_OSX_SYSROOT="${PLATFORM_SDK}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DBUILD_SHARED_LIBS=OFF \
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
    --cross-file "${CROSS_DIR}/${CURRENT_PLATFORM}.cross" \
    --prefix "${PREFIX}" \
    --libdir lib \
    --buildtype release \
    --default-library static \
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
    CFLAGS="${CFLAGS:-} ${PLATFORM_ARCH_FLAGS} -fPIC -O2" \
    CXXFLAGS="${CXXFLAGS:-} ${PLATFORM_ARCH_FLAGS} -fPIC -O2" \
    LDFLAGS="${LDFLAGS:-} ${PLATFORM_ARCH_FLAGS}" \
    ./configure \
      --host="aarch64-apple-darwin" \
      --prefix="${PREFIX}" \
      --libdir="${PREFIX}/lib" \
      --enable-static --disable-shared \
      "$@"
    make -j"${NPROC}"
    make install
  )
}

# ---------------------------------------------------------------------------
# Install-tree post-processing
#
# The sysroot ships STATIC archives (.a). Stripping an archive would drop the
# global symbols the engine links against, so there is nothing to strip here;
# the hook is kept for parity with the rest of the tooling.
# ---------------------------------------------------------------------------
strip_install() {
  :
}
