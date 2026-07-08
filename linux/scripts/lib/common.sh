#!/usr/bin/env bash
# Shared helpers for building the Nordstjernen Linux GTK overlay on Ubuntu.
# Sourced by build-linux-deps.sh and fetch-prebuilt-deps.sh.
#
# Unlike the android/ and ios/ helpers there is no cross toolchain here: this is
# a plain native build with the host compiler, meson/ninja and pkg-config, so
# the machinery is deliberately smaller. What it keeps from the mobile scripts
# is the manifest-driven, checksum-verified, cached download of source tarballs.

set -euo pipefail

if [ "${NORDSTJERNEN_LINUX_VERBOSE:-0}" != "0" ]; then
  set -x
fi

# ---------------------------------------------------------------------------
# Constants / layout (this file lives in linux/scripts/lib/).
# ---------------------------------------------------------------------------
ALL_ARCHS=(x86_64)
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(cd "${COMMON_SH_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${LINUX_DIR}/.." && pwd)"
MANIFEST_FILE="${LINUX_DIR}/deps/manifest.txt"

log()  { printf '\033[1;34m[deps]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[deps] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deps] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

is_valid_arch() {
  local a
  for a in "${ALL_ARCHS[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

# Host architecture as one of ALL_ARCHS.
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "$(uname -m)" ;;
  esac
}

log_tool_versions() {
  local tool
  log "Build host: $(uname -a)"
  for tool in bash meson ninja cmake pkg-config python3 cc gcc make curl tar sha256sum; do
    if command -v "${tool}" >/dev/null 2>&1; then
      log "tool ${tool}: $(command -v "${tool}")"
      case "${tool}" in
        meson|ninja|cmake|pkg-config|python3|make|curl|tar)
          "${tool}" --version 2>&1 | head -2 | sed 's/^/[deps]   /' >&2 || true
          ;;
      esac
    else
      warn "tool ${tool}: missing"
    fi
  done
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

# Names whose checksum is still the AUTO sentinel (echoed one per line).
unpinned_deps() {
  local n
  for n in "${DEP_ORDER[@]}"; do
    case "${DEP_SHA256[$n]}" in [Aa][Uu][Tt][Oo]) echo "${n}" ;; esac
  done
}

# ---------------------------------------------------------------------------
# Download + verify + extract
#
# Tarballs are cached under ${TARBALL_CACHE} (default linux/.cache/tarballs) and
# re-verified on every run. The cache filename is prefixed with the dependency
# name so two deps sharing a generic archive basename can never collide.
# ---------------------------------------------------------------------------
TARBALL_CACHE="${TARBALL_CACHE:-${LINUX_DIR}/.cache/tarballs}"
UA="nordstjernen-linux-deps/1.0 (+https://github.com/nordstjernen-web/nordstjernen-dependencies-build)"

# Echo the cache path for a dependency's tarball (no I/O).
tarball_path() {
  local name="$1"; local url="${DEP_URL[$name]:-}"
  [ -n "${url}" ] || die "no manifest entry for '${name}'"
  printf '%s/%s-%s' "${TARBALL_CACHE}" "${name}" "$(basename "${url}")"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# Ensure a dependency's tarball is present in the cache and matches its sha256,
# downloading it if missing/corrupt. Idempotent and safe to run in parallel
# (each dep writes a distinct file). Does NOT extract.
#
# If the manifest sha256 is the literal AUTO, the download is NOT verified;
# instead the real checksum is printed as a `PINME <name> <sha>` line so it can
# be copied back into the manifest. AUTO is a pin-time convenience only and is
# rejected on main by the CI workflow.
download_verify() {
  local name="$1"
  local url="${DEP_URL[$name]:-}"; local sha="${DEP_SHA256[$name]:-}"
  [ -n "${url}" ] || die "no manifest entry for '${name}'"
  mkdir -p "${TARBALL_CACHE}"
  local file; file="$(tarball_path "${name}")"

  local auto=0
  case "${sha}" in [Aa][Uu][Tt][Oo]) auto=1 ;; esac

  if [ ! -f "${file}" ] || { [ "${auto}" -eq 0 ] && ! echo "${sha}  ${file}" | sha256sum -c - >/dev/null 2>&1; }; then
    log "Downloading ${name} ${DEP_VERSION[$name]} from ${url}"
    # A real User-Agent avoids 4xx from picky upstreams. --retry-all-errors
    # retries non-transient HTTP codes too (some GNOME mirrors intermittently
    # 429/503 under load). Fail loudly so a download error is not later
    # misreported as a checksum mismatch.
    if ! curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
              -A "${UA}" -o "${file}.tmp" "${url}"; then
      rm -f "${file}.tmp"
      die "download failed for ${name} from ${url}"
    fi
    mv "${file}.tmp" "${file}"
  fi

  local actual; actual="$(sha256_of "${file}")"
  if [ "${auto}" -eq 1 ]; then
    warn "${name} checksum is AUTO (unpinned); NOT verifying"
    log  "PINME ${name} ${actual}"
    echo "::warning::${name} is unpinned; pin manifest sha256 to ${actual}" >&2
  elif [ "${actual}" != "${sha}" ]; then
    die "checksum mismatch for ${name} (${file}): expected ${sha}, got ${actual}"
  fi
}

# Download every (or the named) dependency tarball up front, a few at a time.
# BEST-EFFORT warm-up: a failed prefetch must NOT fail the build -- the
# authoritative, retrying download still happens in fetch_source at build time.
_prefetch_batch() {
  local n p rc=0 pids=()
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
# Build environment shared by every dependency
# ---------------------------------------------------------------------------
setup_build_env() {
  # Prepend our prefix so a freshly built library shadows any system copy of the
  # same name. PKG_CONFIG_PATH is *additive* to pkg-config's built-in search
  # path, so the system libraries GTK builds against (glib, cairo, pango,
  # gdk-pixbuf, graphene, libepoxy, ...) stay discoverable.
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
  export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
  export LD_LIBRARY_PATH="${PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

  # ccache accelerates reruns. Meson and CMake pick it up automatically when it
  # is on PATH, so we only need to point it at a cache dir -- do NOT fold it into
  # $CC (a multi-word CC upsets meson's compiler probe).
  if command -v ccache >/dev/null 2>&1; then
    export CCACHE_DIR="${CCACHE_DIR:-${LINUX_DIR}/.cache/ccache}"
    mkdir -p "${CCACHE_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# Build-system wrappers. Each builds out-of-tree and installs into ${PREFIX}.
# ---------------------------------------------------------------------------
NPROC="$( (nproc 2>/dev/null || echo 4) )"

# Keep only the -Dkey=value options whose key is actually defined by the
# project, so a renamed/removed option across GTK versions is skipped (with a
# warning) instead of aborting `meson setup` with "Unknown option". GTK renamed
# meson_options.txt -> meson.options, so check both.
filter_meson_opts() {
  local src="$1"; shift
  local optfile=""
  [ -f "${src}/meson.options" ]     && optfile="${src}/meson.options"
  [ -z "${optfile}" ] && [ -f "${src}/meson_options.txt" ] && optfile="${src}/meson_options.txt"
  local o key
  for o in "$@"; do
    key="${o#-D}"; key="${key%%=*}"
    if [ -z "${optfile}" ] || grep -Eq "option\(\s*'${key}'" "${optfile}"; then
      printf '%s\n' "${o}"
    else
      warn "dropping unknown meson option for this version: ${o}"
    fi
  done
}

build_meson() {  # build_meson <srcdir> [extra -D args...]
  local src="$1"; shift
  local b="${src}/_build"
  rm -rf "${b}"
  local opts=(); mapfile -t opts < <(filter_meson_opts "${src}" "$@")
  log "meson source=${src} build=${b} prefix=${PREFIX}"
  meson setup "${b}" "${src}" \
    --prefix "${PREFIX}" \
    --libdir lib \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Dpkg_config_path="${PKG_CONFIG_PATH}" \
    "${opts[@]}"
  meson compile -C "${b}"
  meson install -C "${b}"
}

build_cmake() {  # build_cmake <srcdir> [extra -D args...]
  local src="$1"; shift
  local b="${src}/_build"
  rm -rf "${b}"
  log "cmake source=${src} build=${b} prefix=${PREFIX}"
  cmake -G Ninja -S "${src}" -B "${b}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DBUILD_SHARED_LIBS=ON \
    "$@"
  cmake --build "${b}" --parallel "${NPROC}"
  cmake --install "${b}"
}

# Strip installed shared libraries to keep the artifact small.
strip_install() {
  find "${PREFIX}/lib" -name '*.so*' -type f -print0 2>/dev/null \
    | xargs -0 -r -n1 strip --strip-unneeded 2>/dev/null || true
}
