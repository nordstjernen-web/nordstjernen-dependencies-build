#!/usr/bin/env bash
# Build the Nordstjernen desktop "GTK overlay" for Linux (Ubuntu) and install it
# into a prefix that the desktop engine (and local developers) can point at to
# test against a bleeding-edge development GTK:
#
#   $NORDSTJERNEN_LINUX_SYSROOT/<arch>/{include,lib,lib/pkgconfig,bin,share}
#
# Usage:
#   build-linux-deps.sh [<arch>] [--sysroot DIR] [--only name1,name2,...]
#
#   <arch>       x86_64 (default: the host architecture)
#   --sysroot    install base (default $NORDSTJERNEN_LINUX_SYSROOT or
#                linux/sysroot); the prefix becomes <sysroot>/<arch>
#   --only       build only the listed deps (comma separated) -- for debugging
#
# Requires: a C/C++ toolchain, meson (>= 1.5), ninja, cmake, pkg-config, python3
# and GTK's build dependencies (glib, cairo, pango, gdk-pixbuf, graphene,
# libepoxy, harfbuzz, wayland, ... ) provided by the distro. On Ubuntu:
#     sudo apt-get build-dep gtk4
#
# Unlike the android/ios sysroots, this does NOT rebuild the GLib/cairo/pango
# stack: GTK is compiled against the system libraries. Only pieces Ubuntu does
# not package (a development release of GTK) are built from source.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CURRENT_ARCH=""
SYSROOT_BASE="${NORDSTJERNEN_LINUX_SYSROOT:-${LINUX_DIR}/sysroot}"
ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sysroot) SYSROOT_BASE="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*)        die "unknown option: $1" ;;
    *)         CURRENT_ARCH="$1"; shift ;;
  esac
done
[ -n "${CURRENT_ARCH}" ] || CURRENT_ARCH="$(host_arch)"
is_valid_arch "${CURRENT_ARCH}" || die "unsupported arch: ${CURRENT_ARCH} (supported: ${ALL_ARCHS[*]})"
[ "${CURRENT_ARCH}" = "$(host_arch)" ] || \
  die "cross-arch builds are not supported here; host is $(host_arch), requested ${CURRENT_ARCH}"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
log_tool_versions
load_manifest

export PREFIX="${SYSROOT_BASE}/${CURRENT_ARCH}"
export BUILD_ROOT="${LINUX_DIR}/.build/${CURRENT_ARCH}"
mkdir -p "${PREFIX}/lib/pkgconfig" "${PREFIX}/include" "${BUILD_ROOT}/src"

setup_build_env

want() {  # honor --only filter
  [ -z "${ONLY}" ] && return 0
  case ",${ONLY}," in *,"$1",*) return 0 ;; *) return 1 ;; esac
}

# ===========================================================================
# Per-dependency builds
# ===========================================================================

dep_gtk() {
  local s; s="$(fetch_source gtk)"
  # Build the shared library only; skip everything that pulls extra tooling or
  # bloats the artifact (docs, man pages, demos, the test suite, GObject
  # introspection, the GStreamer media backend). The wayland/x11 backends,
  # the GL/Vulkan renderers and the CUPS print backend keep their meson
  # defaults (enabled when their system deps are present, which apt build-dep
  # installs). filter_meson_opts drops any option name a given GTK version does
  # not define, so this list is safe across the 4.2x series.
  build_meson "${s}" \
    -Dintrospection=disabled \
    -Ddocumentation=false \
    -Dman-pages=false \
    -Dbuild-tests=false \
    -Dbuild-testsuite=false \
    -Dbuild-examples=false \
    -Ddemos=false \
    -Dmedia-gstreamer=disabled
}

# Ordered build plan.
BUILD_PLAN=(gtk)

log "==> Building Nordstjernen Linux GTK overlay for ${CURRENT_ARCH}"
log "    Prefix:  ${PREFIX}"
log "    Deps:    ${#DEP_ORDER[@]} pinned in manifest"
log "    Verbose: ${NORDSTJERNEN_LINUX_VERBOSE:-0}"

# Warn early (once) about any unpinned dependency.
while read -r u; do
  [ -n "${u}" ] && warn "manifest dependency '${u}' is unpinned (AUTO); pin it before merging to main"
done < <(unpinned_deps)

# Download all source tarballs up front and in parallel.
if [ -n "${ONLY}" ]; then
  prefetch_sources ${ONLY//,/ }
else
  prefetch_sources
fi

for step in "${BUILD_PLAN[@]}"; do
  want "${step}" || { log "skip ${step} (filtered)"; continue; }
  log "--- ${step} ---"
  "dep_${step}"
done

strip_install

log "==> Done. GTK overlay for ${CURRENT_ARCH} installed under ${PREFIX}"
log "    Libraries:"
( cd "${PREFIX}/lib" 2>/dev/null && ls -1 libgtk-4.so* 2>/dev/null | sed 's/^/      /' ) || true
log "    pkg-config modules:"
( cd "${PREFIX}/lib/pkgconfig" 2>/dev/null && ls -1 gtk4*.pc 2>/dev/null | sed 's/^/      /' ) || true

# Re-print pin suggestions at the very end so they are easy to find in CI logs.
unpinned="$(unpinned_deps)"
if [ -n "${unpinned}" ]; then
  warn "Some dependencies are unpinned. Suggested manifest checksums:"
  for n in ${unpinned}; do
    f="$(tarball_path "${n}")"
    [ -f "${f}" ] && log "    ${n}  <-  $(sha256_of "${f}")"
  done
fi
