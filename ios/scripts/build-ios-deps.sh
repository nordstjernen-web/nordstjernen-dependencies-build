#!/usr/bin/env bash
# Cross-compile the full third-party dependency stack for ONE iOS PLATFORM and
# install it into a sysroot prefix that nordstjernen's ios/scripts/build-deps.sh
# can consume:  $NORDSTJERNEN_IOS_SYSROOT/<platform>
#
# Usage:
#   build-ios-deps.sh <platform> [--sysroot DIR] [--only name1,name2,...]
#
#   <platform>   device | simulator
#   --sysroot    install base (default $NORDSTJERNEN_IOS_SYSROOT or
#                ios/sysroot); the prefix becomes <sysroot>/<platform>
#   --only       build only the listed deps (comma separated) -- for debugging
#
# Requires: Xcode with the iOS SDK (xcrun on PATH), meson, ninja, cmake>=3.22,
# pkg-config, and a Python 3. Build systems used per dependency are chosen to
# match upstream's best-supported cross path (CMake / Meson / Autotools). Every
# library is built STATIC (.a), the iOS convention.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CURRENT_PLATFORM=""
SYSROOT_BASE="${NORDSTJERNEN_IOS_SYSROOT:-${IOS_DIR}/sysroot}"
ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sysroot) SYSROOT_BASE="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         CURRENT_PLATFORM="$1"; shift ;;
  esac
done
[ -n "${CURRENT_PLATFORM}" ] || die "platform argument is required (one of: ${ALL_PLATFORMS[*]})"
is_valid_platform "${CURRENT_PLATFORM}" || die "invalid platform: ${CURRENT_PLATFORM}"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
require_toolchain
log_tool_versions
set_platform_env "${CURRENT_PLATFORM}"
load_manifest

export PREFIX="${SYSROOT_BASE}/${CURRENT_PLATFORM}"
export BUILD_ROOT="${IOS_DIR}/.build/${CURRENT_PLATFORM}"
mkdir -p "${PREFIX}/lib/pkgconfig" "${PREFIX}/include" "${BUILD_ROOT}/src"

setup_build_env
# Regenerate the meson cross-file for this platform against this sysroot prefix.
NORDSTJERNEN_IOS_SYSROOT="${SYSROOT_BASE}" "${SCRIPT_DIR}/gen-cross-files.sh" "${CURRENT_PLATFORM}"

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
  # JIT is OFF on iOS: the platform forbids executable memory / JIT for normal
  # (non-entitled) apps, and pcre2's sljit allocator does not compile for the
  # iOS target. GLib's regex works fine with the interpreted matcher.
  build_cmake "${s}" \
    -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=ON -DPCRE2_BUILD_PCRE2_32=ON \
    -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_SUPPORT_JIT=OFF
}

dep_expat() {
  local s; s="$(fetch_source expat)"
  build_cmake "${s}" \
    -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
    -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_SHARED_LIBS=OFF
}

dep_glib() {
  local s; s="$(fetch_source glib)"
  # Apple's libc ships no gettext/libintl, so glib falls back to its bundled
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
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
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
  build_meson "${s}" -Dtests=disabled -Dgtk=disabled -Dlibpng=enabled
}

dep_fontconfig() {
  local s; s="$(fetch_source fontconfig)"
  # fcint.h uses locale_t and the LC_*_MASK constants but only includes
  # <xlocale.h> when its own HAVE_XLOCALE_H probe succeeds, which it does not
  # under the iOS cross-configure. Add the include in-source, right before the
  # first use. This mirrors the native-macOS build (where HAVE_XLOCALE_H is set)
  # and, unlike a compiler-level -include, does not get injected into
  # fontconfig's gperf codegen preprocess (which would corrupt fcobjshash).
  perl -0777 -pi -e 's/\ntypedef locale_t FcLocale;/\n#include <xlocale.h>\ntypedef locale_t FcLocale;/' \
    "${s}/src/fcint.h"
  grep -B1 'typedef locale_t FcLocale;' "${s}/src/fcint.h" | grep -q '#include <xlocale.h>' \
    || die "fontconfig: fcint.h xlocale patch did not apply"
  build_meson "${s}" \
    -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled
}

dep_cairo() {
  local s; s="$(fetch_source cairo)"
  # tests=disabled drops cairo-boilerplate, which calls system() — a function
  # iOS marks unavailable. Only the library is needed.
  build_meson "${s}" \
    -Dxlib=disabled -Dxcb=disabled -Dquartz=disabled \
    -Dfreetype=enabled -Dfontconfig=enabled -Dpng=enabled -Dzlib=enabled \
    -Dglib=enabled -Dtests=disabled
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
    # The classic iOS OpenSSL cross env: CROSS_TOP is the platform's Developer
    # directory and CROSS_SDK the SDK basename; the ios-common config derives
    # -isysroot from them, on top of the target's -arch and min-version flags.
    export CROSS_TOP="$(dirname "$(dirname "${SDKROOT}")")"
    export CROSS_SDK="$(basename "${SDKROOT}")"
    ./Configure "${PLATFORM_OPENSSL_TARGET}" \
      no-shared no-tests no-apps no-engine \
      --prefix="${PREFIX}" --libdir=lib
    make -j"${NPROC}"
    make install_sw install_ssldirs
  )
}

dep_nghttp2() {
  local s; s="$(fetch_source nghttp2)"
  # nghttp2 1.69 selects the library target from the standard CMake
  # BUILD_STATIC_LIBS / BUILD_SHARED_LIBS (not the older ENABLE_*_LIB). With
  # BUILD_SHARED_LIBS=OFF (from build_cmake) the alias picks nghttp2_static, so
  # that target must actually be built — hence BUILD_STATIC_LIBS=ON.
  build_cmake "${s}" \
    -DENABLE_LIB_ONLY=ON -DBUILD_STATIC_LIBS=ON \
    -DENABLE_DOC=OFF -DBUILD_TESTING=OFF
}

dep_brotli() {
  local s; s="$(fetch_source brotli)"
  # Static libbrotlicommon/dec/enc + pkg-config files; libcurl links brotlidec
  # to decode `Content-Encoding: br`.
  build_cmake "${s}" -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_DISABLE_TESTS=ON
}

dep_sqlite3() {
  local s; s="$(fetch_source sqlite3)"
  # The autoconf build also compiles the sqlite3 shell (shell.c), which calls
  # system() — unavailable on iOS. Only the library is needed, so compile the
  # single-file amalgamation straight into a static lib and install the headers
  # and a pkg-config file. Flags match sqlite-autoconf's library defaults.
  ( cd "${s}"
    ${CC_LAUNCHER:+${CC_LAUNCHER} }"${CC}" ${PLATFORM_ARCH_FLAGS} -fPIC -O2 -I. \
      -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_MATH_FUNCTIONS \
      -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE \
      -c sqlite3.c -o sqlite3.o
    "${AR}" crs "${PREFIX}/lib/libsqlite3.a" sqlite3.o
    cp -f sqlite3.h sqlite3ext.h "${PREFIX}/include/"
    cat > "${PREFIX}/lib/pkgconfig/sqlite3.pc" <<EOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: SQLite
Description: SQL database engine
Version: ${DEP_VERSION[sqlite3]}
Libs: -L\${libdir} -lsqlite3
Cflags: -I\${includedir}
EOF
  )
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
  # curl defaults CURL_USE_PKGCONFIG=OFF on Apple, so its FindBrotli does not
  # locate our static brotli via pkg-config and brotli silently drops out. Give
  # FindBrotli explicit absolute-path hints (its documented input variables) so
  # BROTLI_FOUND is set and content_encoding.c compiles the `Content-Encoding:
  # br` decoder.
  build_cmake "${s}" \
    -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
    -DCURL_USE_OPENSSL=ON -DUSE_NGHTTP2=ON -DCURL_USE_LIBPSL=ON \
    -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DUSE_LIBIDN2=OFF \
    -DCURL_ZLIB=ON -DCURL_BROTLI=ON -DCURL_ZSTD=OFF -DENABLE_THREADED_RESOLVER=ON \
    -DBROTLI_USE_STATIC_LIBS=ON \
    -DBROTLI_INCLUDE_DIR="${PREFIX}/include" \
    -DBROTLICOMMON_LIBRARY="${PREFIX}/lib/libbrotlicommon.a" \
    -DBROTLIDEC_LIBRARY="${PREFIX}/lib/libbrotlidec.a" \
    -DHTTP_ONLY=OFF
}

# Ordered build plan. freetype is built twice to resolve the harfbuzz cycle.
# brotli precedes curl so libcurl can link it for `Content-Encoding: br`.
# No llama.cpp here: on-device inference is not part of the mobile iOS build.
BUILD_PLAN=(
  zlib libffi pcre2 expat
  glib
  libpng freetype_stage1 harfbuzz freetype_stage2
  fribidi pixman fontconfig
  cairo pango
  openssl nghttp2 brotli
  sqlite3 uchardet libpsl libwebp
  curl
)

log "==> Building iOS dependency sysroot for ${CURRENT_PLATFORM}"
log "    SDK:      ${PLATFORM_SDK}"
log "    Prefix:   ${PREFIX}"
log "    Deps:     ${#DEP_ORDER[@]} pinned in manifest"
log "    Verbose:  ${NORDSTJERNEN_IOS_VERBOSE:-0}"

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

log "==> Done. Sysroot for ${CURRENT_PLATFORM} installed under ${PREFIX}"
log "    Libraries:"
( cd "${PREFIX}/lib" 2>/dev/null && ls -1 *.a 2>/dev/null | sed 's/^/      /' ) || true
log "    pkg-config modules:"
( cd "${PREFIX}/lib/pkgconfig" 2>/dev/null && ls -1 *.pc 2>/dev/null | sed 's/^/      /' ) || true
