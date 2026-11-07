#!/usr/bin/env bash
# Download the prebuilt Linux GTK overlay published by the "build-linux-deps"
# GitHub Actions workflow as a public Release, and lay it out so the desktop
# Nordstjernen engine can consume it via $NORDSTJERNEN_LINUX_SYSROOT.
#
# Release assets (under the rolling tag, default 'linux-gtk-latest'):
#   nordstjernen-linux-gtk-<arch>.tar.gz   # each contains a top-level <arch>/
#   SHA256SUMS                             # checksums for verification
#   (each asset also carries a GitHub build-provenance attestation, verified
#    with `gh attestation verify` when gh is installed -- see verify_attestation)
#   manifest.txt                           # pinned versions that were built
#
# These are public, so no authentication (and no `gh` CLI) is required -- just
# curl, tar and sha256sum. After running, the layout is:
#   $SYSROOT/x86_64/{include,lib,lib/pkgconfig,bin,share}
#
# Usage:
#   fetch-prebuilt-deps.sh [options]
#     --sysroot DIR     destination base (default: $NORDSTJERNEN_LINUX_SYSROOT
#                       or linux/sysroot)
#     --arch ARCH       download only one arch (default: the host arch)
#     --repo OWNER/REPO GitHub repo (default: nordstjernen-web/nordstjernen-dependencies-build)
#     --tag TAG         release tag to download (default: linux-gtk-latest)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="nordstjernen-web/nordstjernen-dependencies-build"
TAG="linux-gtk-latest"
SYSROOT_BASE="${NORDSTJERNEN_LINUX_SYSROOT:-${LINUX_DIR}/sysroot}"
ARCHS=("$(host_arch)")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sysroot) SYSROOT_BASE="$2"; shift 2 ;;
    --arch)    ARCHS=("$2"); shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --tag)     TAG="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v curl      >/dev/null 2>&1 || die "curl is required"
command -v sha256sum  >/dev/null 2>&1 || die "sha256sum is required"

BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
mkdir -p "${SYSROOT_BASE}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

dl() { curl -fsSL --proto '=https' --proto-redir '=https' --retry 4 --retry-delay 2 -A "${UA}" -o "$2" "$1"; }

# Verify the GitHub build-provenance attestation of a downloaded asset when the
# gh CLI is available. SHA256SUMS comes from the same release as the tarball,
# so it only proves the download is intact; the attestation proves the asset
# was produced by this repository's workflow from a specific commit. Set
# NORDSTJERNEN_REQUIRE_ATTESTATION=1 to make a missing gh fatal; a failed
# check is always fatal.
verify_attestation() {
  local file="$1"
  if ! command -v gh >/dev/null 2>&1; then
    if [ "${NORDSTJERNEN_REQUIRE_ATTESTATION:-0}" != "0" ]; then
      die "gh CLI not found but NORDSTJERNEN_REQUIRE_ATTESTATION is set; install gh to verify ${file##*/}"
    fi
    warn "gh CLI not found; skipping provenance verification of ${file##*/} (set NORDSTJERNEN_REQUIRE_ATTESTATION=1 to require it)"
    return 0
  fi
  gh attestation verify "${file}" --repo "${REPO}" >/dev/null 2>&1 \
    || die "provenance attestation check FAILED for ${file##*/} (repo ${REPO}); refusing to install"
  log "verified build provenance of ${file##*/}"
}

log "Downloading checksum manifest from ${TAG}"
dl "${BASE_URL}/SHA256SUMS" "${tmp}/SHA256SUMS" \
  || die "could not fetch SHA256SUMS from release '${TAG}' (does it exist yet?)"

for arch in "${ARCHS[@]}"; do
  is_valid_arch "${arch}" || die "unsupported arch: ${arch}"
  asset="nordstjernen-linux-gtk-${arch}.tar.gz"
  log "Downloading ${asset}"
  dl "${BASE_URL}/${asset}" "${tmp}/${asset}" || die "download failed for ${asset}"

  # Verify against the published SHA256SUMS (entries are like "./<asset>").
  want="$(awk -v f="${asset}" '$2 ~ ("(^|/)" f "$") {print $1}' "${tmp}/SHA256SUMS" | head -1)"
  [ -n "${want}" ] || die "no checksum for ${asset} in SHA256SUMS"
  echo "${want}  ${tmp}/${asset}" | sha256sum -c - >/dev/null \
    || die "checksum mismatch for ${asset}"
  verify_attestation "${tmp}/${asset}"

  rm -rf "${SYSROOT_BASE:?}/${arch}"
  # Tarball carries a top-level <arch>/ dir, so extract straight into the base.
  tar -xzf "${tmp}/${asset}" -C "${SYSROOT_BASE}"
  [ -d "${SYSROOT_BASE}/${arch}/lib" ] || die "unexpected archive layout for ${arch}"
  log "Installed ${arch} -> ${SYSROOT_BASE}/${arch}"
done

cat >&2 <<EOF

Prebuilt GTK overlay ready. To test the desktop engine against it, put the
overlay ahead of the system GTK, e.g.:

    export NORDSTJERNEN_LINUX_SYSROOT="${SYSROOT_BASE}"
    ARCH="$(host_arch)"
    export PKG_CONFIG_PATH="\${NORDSTJERNEN_LINUX_SYSROOT}/\${ARCH}/lib/pkgconfig:\${PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="\${NORDSTJERNEN_LINUX_SYSROOT}/\${ARCH}/lib:\${LD_LIBRARY_PATH}"
    # pkg-config recomputes the prefix from the .pc location:
    export PKG_CONFIG="pkg-config --define-prefix"

then build/run the engine as usual. It must run on the same Ubuntu release the
overlay was built on so the system glib/cairo/pango/... stay ABI-compatible.
EOF
