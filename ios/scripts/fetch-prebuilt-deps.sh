#!/usr/bin/env bash
# Download the prebuilt iOS dependency sysroot published by the "build-ios-deps"
# GitHub Actions workflow as a public Release, and lay it out so nordstjernen's
# ios/scripts/build-deps.sh can consume it via $NORDSTJERNEN_IOS_SYSROOT.
#
# Release assets (under the rolling tag, default 'ios-sysroot-latest'):
#   nordstjernen-ios-sysroot-<platform>.tar.gz  # each contains a top-level <platform>/
#   SHA256SUMS                                  # checksums for verification
#   (each asset also carries a GitHub build-provenance attestation, verified
#    with `gh attestation verify` when gh is installed -- see verify_attestation)
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
#     --repo OWNER/REPO    GitHub repo (default: nordstjernen-web/nordstjernen-dependencies-build)
#     --tag TAG            release tag to download (default: ios-sysroot-latest)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="nordstjernen-web/nordstjernen-dependencies-build"
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
dl() { curl -fsSL --proto '=https' --proto-redir '=https' --retry 4 --retry-delay 2 -A "${UA}" -o "$2" "$1"; }

# Verify a downloaded asset's GitHub build-provenance attestation. SHA256SUMS
# comes from the same release as the tarball, so it only proves the download is
# intact; the attestation proves the asset was produced by this repository's
# workflow from a specific commit. Needs an authenticated gh CLI (GH_TOKEN on
# CI). Policy:
#   - gh missing or unauthenticated   -> warn (fatal with NORDSTJERNEN_REQUIRE_ATTESTATION=1)
#   - no attestation published        -> warn (fatal with NORDSTJERNEN_REQUIRE_ATTESTATION=1);
#                                        happens when Sigstore was down at publish time
#   - attestation present but invalid -> always fatal
verify_attestation() {
  local file="$1" name="${1##*/}"
  local required="${NORDSTJERNEN_REQUIRE_ATTESTATION:-0}"
  soft_fail() {
    if [ "${required}" != "0" ]; then die "$1 (NORDSTJERNEN_REQUIRE_ATTESTATION is set)"; fi
    warn "$1; skipping provenance verification of ${name} (set NORDSTJERNEN_REQUIRE_ATTESTATION=1 to require it)"
  }
  if ! command -v gh >/dev/null 2>&1; then soft_fail "gh CLI not found"; return 0; fi
  if ! gh auth status >/dev/null 2>&1; then soft_fail "gh CLI is not authenticated (set GH_TOKEN)"; return 0; fi
  local digest count
  digest="$(sha256bin "${file}" | awk '{print $1}')"
  count="$(gh api "repos/${REPO}/attestations/sha256:${digest}" --jq '.attestations | length' 2>/dev/null || echo "")"
  if [ -z "${count}" ]; then soft_fail "could not query the attestations API for ${name}"; return 0; fi
  if [ "${count}" = "0" ]; then soft_fail "no build-provenance attestation is published for ${name}"; return 0; fi
  gh attestation verify "${file}" --repo "${REPO}" >/dev/null 2>&1 \
    || die "provenance attestation check FAILED for ${name} (repo ${REPO}); refusing to install"
  log "verified build provenance of ${name}"
}

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
  verify_attestation "${tmp}/${asset}"

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
