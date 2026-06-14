#!/usr/bin/env bash
# Cross-compile the full third-party dependency stack for ONE Android ABI and
# install it into a sysroot prefix that nordstjernen's android/scripts/
# build-deps.sh can consume:  $NORDSTJERNEN_ANDROID_SYSROOT/<abi>
#
# Usage:
#   build-android-deps.sh <abi> [--sysroot DIR] [--only name1,name2,...]
#
#   <abi>        arm64-v8a | armeabi-v7a | x86_64 | x86
#   --sysroot    install base (default $NORDSTJERNEN_ANDROID_SYSROOT or
#                android/sysroot); the prefix becomes <sysroot>/<abi>
#   --only       build only the listed deps (comma separated) -- for debugging
#
# Requires: Android NDK r27 (ANDROID_NDK_HOME), meson, ninja, cmake>=3.22,
# pkg-config, and a Python 3. Build systems used per dependency are chosen to
# match upstream's best-supported cross path (CMake / Meson / Autotools).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CURRENT_ABI=""
SYSROOT_BASE="${NORDSTJERNEN_ANDROID_SYSROOT:-${ANDROID_DIR}/sysroot}"
ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sysroot) SYSROOT_BASE="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         CURRENT_ABI="$1"; shift ;;
  esac
done
[ -n "${CURRENT_ABI}" ] || die "ABI argument is required (one of: ${ALL_ABIS[*]})"
is_valid_abi "${CURRENT_ABI}" || die "invalid ABI: ${CURRENT_ABI}"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
require_ndk
log_tool_versions
set_abi_env "${CURRENT_ABI}"
load_manifest

export PREFIX="${SYSROOT_BASE}/${CURRENT_ABI}"
export BUILD_ROOT="${ANDROID_DIR}/.build/${CURRENT_ABI}"
mkdir -p "${PREFIX}/lib/pkgconfig" "${PREFIX}/include" "${BUILD_ROOT}/src"

setup_build_env
# Regenerate the meson cross-file for this ABI against this sysroot prefix.
NORDSTJERNEN_ANDROID_SYSROOT="${SYSROOT_BASE}" "${SCRIPT_DIR}/gen-cross-files.sh" "${CURRENT_ABI}"

want() {  # honor --only filter
  [ -z "${ONLY}" ] && return 0
  case ",${ONLY}," in *,"$1",*) return 0 ;; *) return 1 ;; esac
}

# ===========================================================================
# Per-dependency builds (in dependency order)
# ===========================================================================

dep_zlib() {
  local s; s="$(fetch_source zlib)"
  build_cmake "${s}" -DZLIB_BUILD_EXAMPLES=OFF
}

dep_libffi() {
  local s; s="$(fetch_source libffi)"
  build_autotools "${s}" --disable-docs
}

dep_pcre2() {
  local s; s="$(fetch_source pcre2)"
  build_cmake "${s}" \
    -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=ON -DPCRE2_BUILD_PCRE2_32=ON \
    -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_JIT=ON
}

dep_expat() {
  local s; s="$(fetch_source expat)"
  build_cmake "${s}" \
    -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
    -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_SHARED_LIBS=ON
}

dep_glib() {
  local s; s="$(fetch_source glib)"
  # Android bionic ships no gettext/libintl, so glib falls back to its bundled
  # proxy-libintl meson subproject. Wrap downloading is disabled
  # (--wrap-mode nodownload, for offline/reproducible builds), so vendor the
  # pinned proxy-libintl source into glib's subprojects/ under the exact
  # directory name its .wrap expects (proxy-libintl-0.5).
  local intl; intl="$(fetch_source proxy-libintl)"
  rm -rf "${s}/subprojects/proxy-libintl-0.5"
  cp -a "${intl}" "${s}/subprojects/proxy-libintl-0.5"
  build_meson "${s}" \
    -Dtests=false -Dglib_assert=false -Dglib_checks=false \
    -Dintrospection=disabled -Dnls=disabled -Dman-pages=disabled \
    -Ddtrace=disabled -Dsystemtap=disabled -Dlibmount=disabled \
    -Dselinux=disabled -Dxattr=false
}

dep_libpng() {
  local s; s="$(fetch_source libpng)"
  build_cmake "${s}" \
    -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
    -DPNG_FRAMEWORK=OFF
}

# freetype <-> harfbuzz cycle: build freetype without harfbuzz first, build
# harfbuzz, then rebuild freetype with harfbuzz enabled.
dep_freetype_stage1() {
  local s; s="$(fetch_source freetype)"
  build_meson "${s}" \
    -Dharfbuzz=disabled -Dpng=enabled -Dzlib=system \
    -Dbrotli=disabled -Dbzip2=disabled
}

dep_harfbuzz() {
  local s; s="$(fetch_source harfbuzz)"
  build_meson "${s}" \
    -Dglib=enabled -Dfreetype=enabled -Dgobject=disabled \
    -Dcairo=disabled -Dicu=disabled -Dtests=disabled \
    -Ddocs=disabled -Dutilities=disabled
}

dep_freetype_stage2() {
  local s; s="$(fetch_source freetype)"
  build_meson "${s}" \
    -Dharfbuzz=enabled -Dpng=enabled -Dzlib=system \
    -Dbrotli=disabled -Dbzip2=disabled
}

dep_fribidi() {
  local s; s="$(fetch_source fribidi)"
  build_meson "${s}" -Dtests=false -Ddocs=false -Dbin=false
}

dep_pixman() {
  local s; s="$(fetch_source pixman)"
  local extra=()
  # 32-bit ARM: pixman's NEON runtime detection (pixman-arm.c) includes the
  # NDK's <cpu-features.h> (android_getCpuFamily/Features), which is not on the
  # default sysroot include path. pixman's cpu-features-path option compiles the
  # NDK helper straight into the library. arm64/x86/x86_64 don't hit this path.
  if [ "${CURRENT_ABI}" = "armeabi-v7a" ]; then
    local cf="${ANDROID_NDK_HOME}/sources/android/cpufeatures"
    [ -f "${cf}/cpu-features.c" ] || die "NDK cpufeatures helper not found at ${cf}"
    extra+=(-Dcpu-features-path="${cf}")
  fi
  build_meson "${s}" -Dtests=disabled -Dgtk=disabled -Dlibpng=enabled "${extra[@]}"
}

dep_fontconfig() {
  local s; s="$(fetch_source fontconfig)"
  build_meson "${s}" \
    -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled
}

dep_cairo() {
  local s; s="$(fetch_source cairo)"
  build_meson "${s}" \
    -Dxlib=disabled -Dxcb=disabled -Dquartz=disabled \
    -Dfreetype=enabled -Dfontconfig=enabled -Dpng=enabled -Dzlib=enabled \
    -Dglib=enabled
}

dep_pango() {
  local s; s="$(fetch_source pango)"
  build_meson "${s}" \
    -Dintrospection=disabled -Dgtk_doc=false -Dbuild-testsuite=false \
    -Dbuild-examples=false -Dfontconfig=enabled -Dfreetype=enabled -Dcairo=enabled
}

dep_openssl() {
  local s; s="$(fetch_source openssl)"
  ( cd "${s}"
    export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}"
    # The NDK r27 android${ANDROID_API} target triple already defines
    # __ANDROID_API__, so do not pass -D__ANDROID_API__ (would warn/-Werror).
    PATH="${NDK_BIN}:${PATH}" \
    ./Configure "${ABI_OPENSSL_TARGET}" \
      --prefix="${PREFIX}" --libdir=lib \
      shared no-tests no-apps "${PAGE_SIZE_LDFLAG}" "${UNDEF_VER_LDFLAG}"
    PATH="${NDK_BIN}:${PATH}" make -j"${NPROC}"
    PATH="${NDK_BIN}:${PATH}" make install_sw install_ssldirs
  )
}

dep_nghttp2() {
  local s; s="$(fetch_source nghttp2)"
  build_cmake "${s}" \
    -DENABLE_LIB_ONLY=ON -DENABLE_SHARED_LIB=ON -DENABLE_STATIC_LIB=OFF \
    -DENABLE_DOC=OFF -DBUILD_TESTING=OFF
}

dep_brotli() {
  local s; s="$(fetch_source brotli)"
  # Shared libbrotlicommon/dec/enc + pkg-config files; libcurl links brotlidec
  # to decode `Content-Encoding: br`.
  build_cmake "${s}" -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_DISABLE_TESTS=ON
}

dep_sqlite3() {
  local s; s="$(fetch_source sqlite3)"
  build_autotools "${s}" --disable-static-shell --disable-editline --disable-readline
}

dep_uchardet() {
  local s; s="$(fetch_source uchardet)"
  build_cmake "${s}" -DBUILD_BINARY=OFF
}

dep_libpsl() {
  local s; s="$(fetch_source libpsl)"
  # Use the bundled public-suffix data (built on the host with python3); avoid
  # pulling in libidn2/libunistring at runtime.
  build_autotools "${s}" --enable-builtin=yes --enable-runtime=no
}

dep_libwebp() {
  local s; s="$(fetch_source libwebp)"
  build_cmake "${s}" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
    -DWEBP_BUILD_LIBWEBPMUX=ON
}

dep_curl() {
  local s; s="$(fetch_source curl)"
  build_cmake "${s}" \
    -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
    -DCURL_USE_OPENSSL=ON -DUSE_NGHTTP2=ON -DCURL_USE_LIBPSL=ON \
    -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DUSE_LIBIDN2=OFF \
    -DCURL_ZLIB=ON -DCURL_BROTLI=ON -DCURL_ZSTD=OFF -DENABLE_THREADED_RESOLVER=ON \
    -DHTTP_ONLY=OFF
}

dep_llama() {
  local s; s="$(fetch_source llama)"
  # Cross-compile libllama + ggml only (no tools/examples/server/tests). Pin the
  # cross-unfriendly bits: GGML_NATIVE=OFF (never probe the build host's CPU) and
  # GGML_OPENMP=OFF (bionic ships no libgomp). LLAMA_BUILD_COMMON=OFF drops the
  # curl/build-info helper library the engine does not consume.
  build_cmake "${s}" \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_COMMON=OFF \
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BUILD_TESTS=OFF
}

# Ordered build plan. freetype is built twice to resolve the harfbuzz cycle.
# brotli precedes curl so libcurl can link it for `Content-Encoding: br`.
BUILD_PLAN=(
  zlib libffi pcre2 expat
  glib
  libpng freetype_stage1 harfbuzz freetype_stage2
  fribidi pixman fontconfig
  cairo pango
  openssl nghttp2 brotli
  sqlite3 uchardet libpsl libwebp
  curl
  llama
)

log "==> Building Android dependency sysroot for ${CURRENT_ABI}"
log "    NDK:     ${ANDROID_NDK_HOME}"
log "    Prefix:  ${PREFIX}"
log "    Deps:    ${#DEP_ORDER[@]} pinned in manifest"
log "    Verbose: ${NORDSTJERNEN_ANDROID_VERBOSE:-0}"

# Download all source tarballs up front and in parallel so network latency
# overlaps instead of stalling each serial build step (no CI cache required).
if [ -n "${ONLY}" ]; then
  prefetch_sources ${ONLY//,/ }
else
  prefetch_sources
fi

for step in "${BUILD_PLAN[@]}"; do
  # The --only filter matches manifest names; map the two freetype stages.
  name="${step/_stage[12]/}"
  want "${name}" || { log "skip ${step} (filtered)"; continue; }
  log "--- ${step} ---"
  "dep_${step}"
done

strip_install

log "==> Done. Sysroot for ${CURRENT_ABI} installed under ${PREFIX}"
log "    Libraries:"
( cd "${PREFIX}/lib" 2>/dev/null && ls -1 *.so 2>/dev/null | sed 's/^/      /' ) || true
log "    pkg-config modules:"
( cd "${PREFIX}/lib/pkgconfig" 2>/dev/null && ls -1 *.pc 2>/dev/null | sed 's/^/      /' ) || true
