#!/usr/bin/env bash
# Download the prebuilt Android dependency sysroot published by the "build-deps"
# GitHub Actions workflow as a public Release, and lay it out so nordstjernen's
# android/scripts/build-deps.sh can consume it via $NORDSTJERNEN_ANDROID_SYSROOT.
#
# Release assets (under the rolling tag, default 'sysroot-latest'):
#   nordstjernen-android-sysroot-<abi>.tar.gz   # each contains a top-level <abi>/
#   SHA256SUMS                                  # checksums for verification
#   (each asset also carries a GitHub build-provenance attestation, verified
#    with `gh attestation verify` when gh is installed -- see verify_attestation)
#   manifest.txt                                # pinned versions that were built
#
# These are public, so no authentication (and no `gh` CLI) is required -- just
# curl, tar and sha256sum. After running, the layout is:
#   $SYSROOT/arm64-v8a/{include,lib,lib/pkgconfig}
#   $SYSROOT/x86_64/...  (etc.)
#
# Usage:
#   fetch-prebuilt-deps.sh [options]
#     --sysroot DIR     destination base (default: $NORDSTJERNEN_ANDROID_SYSROOT
#                       or android/sysroot)
#     --abi ABI         download only one ABI (default: all)
#     --repo OWNER/REPO GitHub repo (default: nordstjernen-web/nordstjernen-dependencies-build)
#     --tag TAG         release tag to download (default: sysroot-latest)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="nordstjernen-web/nordstjernen-dependencies-build"
TAG="sysroot-latest"
SYSROOT_BASE="${NORDSTJERNEN_ANDROID_SYSROOT:-${ANDROID_DIR}/sysroot}"
ABIS=("${ALL_ABIS[@]}")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sysroot) SYSROOT_BASE="$2"; shift 2 ;;
    --abi)     ABIS=("$2"); shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --tag)     TAG="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v curl       >/dev/null 2>&1 || die "curl is required"
command -v sha256sum   >/dev/null 2>&1 || die "sha256sum is required"

BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
mkdir -p "${SYSROOT_BASE}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

UA="nordstjernen-android-deps/1.0 (+https://github.com/${REPO})"
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

for abi in "${ABIS[@]}"; do
  is_valid_abi "${abi}" || die "invalid ABI: ${abi}"
  asset="nordstjernen-android-sysroot-${abi}.tar.gz"
  log "Downloading ${asset}"
  dl "${BASE_URL}/${asset}" "${tmp}/${asset}" || die "download failed for ${asset}"

  # Verify against the published SHA256SUMS (entries are like "./<asset>").
  want="$(awk -v f="${asset}" '$2 ~ ("(^|/)" f "$") {print $1}' "${tmp}/SHA256SUMS" | head -1)"
  [ -n "${want}" ] || die "no checksum for ${asset} in SHA256SUMS"
  echo "${want}  ${tmp}/${asset}" | sha256sum -c - >/dev/null \
    || die "checksum mismatch for ${asset}"
  verify_attestation "${tmp}/${asset}"

  rm -rf "${SYSROOT_BASE:?}/${abi}"
  # Tarball carries a top-level <abi>/ dir, so extract straight into the base.
  tar -xzf "${tmp}/${asset}" -C "${SYSROOT_BASE}"
  [ -d "${SYSROOT_BASE}/${abi}/lib" ] || die "unexpected archive layout for ${abi}"
  log "Installed ${abi} -> ${SYSROOT_BASE}/${abi}"
done

cat >&2 <<EOF

Prebuilt sysroot ready. Point the engine build at it with:

    export NORDSTJERNEN_ANDROID_SYSROOT="${SYSROOT_BASE}"

then run android/scripts/build-deps.sh as usual; it will pick up the prebuilt
libraries under \$NORDSTJERNEN_ANDROID_SYSROOT/<abi> instead of compiling them.
EOF
