#!/usr/bin/env bash
# Download the prebuilt iOS dependency sysroot published by the "build-ios-deps"
# GitHub Actions workflow as a public Release, and lay it out so nordstjernen's
# ios/scripts/build-deps.sh can consume it via $NORDSTJERNEN_IOS_SYSROOT.
#
# Release assets (under the rolling tag, default 'ios-sysroot-latest'):
#   nordstjernen-ios-sysroot-<platform>.tar.gz  # each contains a top-level <platform>/
#   SHA256SUMS                                  # checksums for verification
#   manifest.txt                                # pinned versions that were built
#
# These are public, so no authentication (and no `gh` CLI) is required -- just
# curl, tar and a sha256 tool. After running, the layout is:
#   $SYSROOT/device/{include,lib,lib/pkgconfig}
#   $SYSROOT/simulator/...
#
# Usage:
#   fetch-prebuilt-deps.sh [options]
#     --sysroot DIR        destination base (default: $NORDSTJERNEN_IOS_SYSROOT
#                          or ios/sysroot)
#     --platform PLATFORM  download only one platform (default: both)
#     --repo OWNER/REPO    GitHub repo (default: nordstjernen-web/nordstjernen-android)
#     --tag TAG            release tag to download (default: ios-sysroot-latest)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="nordstjernen-web/nordstjernen-android"
TAG="ios-sysroot-latest"
SYSROOT_BASE="${NORDSTJERNEN_IOS_SYSROOT:-${IOS_DIR}/sysroot}"
PLATFORMS=("${ALL_PLATFORMS[@]}")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sysroot)  SYSROOT_BASE="$2"; shift 2 ;;
    --platform) PLATFORMS=("$2"); shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --tag)      TAG="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
  || die "a sha256 tool is required (sha256sum or shasum)"

BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
mkdir -p "${SYSROOT_BASE}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

UA="nordstjernen-ios-deps/1.0 (+https://github.com/${REPO})"
dl() { curl -fsSL --retry 4 --retry-delay 2 -A "${UA}" -o "$2" "$1"; }

log "Downloading checksum manifest from ${TAG}"
dl "${BASE_URL}/SHA256SUMS" "${tmp}/SHA256SUMS" \
  || die "could not fetch SHA256SUMS from release '${TAG}' (does it exist yet?)"

for platform in "${PLATFORMS[@]}"; do
  is_valid_platform "${platform}" || die "invalid platform: ${platform}"
  asset="nordstjernen-ios-sysroot-${platform}.tar.gz"
  log "Downloading ${asset}"
  dl "${BASE_URL}/${asset}" "${tmp}/${asset}" || die "download failed for ${asset}"

  # Verify against the published SHA256SUMS (entries are like "./<asset>").
  want="$(awk -v f="${asset}" '$2 ~ ("(^|/)" f "$") {print $1}' "${tmp}/SHA256SUMS" | head -1)"
  [ -n "${want}" ] || die "no checksum for ${asset} in SHA256SUMS"
  echo "${want}  ${tmp}/${asset}" | sha256bin -c - >/dev/null \
    || die "checksum mismatch for ${asset}"

  rm -rf "${SYSROOT_BASE:?}/${platform}"
  # Tarball carries a top-level <platform>/ dir, so extract straight into the base.
  tar -xzf "${tmp}/${asset}" -C "${SYSROOT_BASE}"
  [ -d "${SYSROOT_BASE}/${platform}/lib" ] || die "unexpected archive layout for ${platform}"
  log "Installed ${platform} -> ${SYSROOT_BASE}/${platform}"
done

cat >&2 <<EOF

Prebuilt sysroot ready. Point the engine build at it with:

    export NORDSTJERNEN_IOS_SYSROOT="${SYSROOT_BASE}"

then run ios/scripts/build-deps.sh as usual; it will pick up the prebuilt
libraries under \$NORDSTJERNEN_IOS_SYSROOT/<platform> instead of compiling them.
EOF
