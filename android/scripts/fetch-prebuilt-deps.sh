#!/usr/bin/env bash
# Download the prebuilt Android dependency sysroot published by the "build-deps"
# GitHub Actions workflow as a public Release, and lay it out so nordstjernen's
# android/scripts/build-deps.sh can consume it via $NORDSTJERNEN_ANDROID_SYSROOT.
#
# Release assets (under the rolling tag, default 'sysroot-latest'):
#   nordstjernen-android-sysroot-<abi>.tar.gz   # each contains a top-level <abi>/
#   SHA256SUMS                                  # checksums for verification
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
dl() { curl -fsSL --retry 4 --retry-delay 2 -A "${UA}" -o "$2" "$1"; }

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
