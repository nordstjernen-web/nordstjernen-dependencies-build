#!/usr/bin/env bash
# Download the prebuilt Android dependency sysroot produced by the
# "build-deps" GitHub Actions workflow and lay it out so that nordstjernen's
# android/scripts/build-deps.sh can consume it via $NORDSTJERNEN_ANDROID_SYSROOT.
#
# The CI workflow uploads one artifact per ABI named
#   nordstjernen-android-sysroot-<abi>
# each containing a top-level <abi>/ directory (include/, lib/, lib/pkgconfig/).
# After running this script the layout is:
#   $SYSROOT/arm64-v8a/{include,lib,lib/pkgconfig}
#   $SYSROOT/armeabi-v7a/...
#   ...
#
# Usage:
#   fetch-prebuilt-deps.sh [options]
#     --sysroot DIR     destination base (default: $NORDSTJERNEN_ANDROID_SYSROOT
#                       or android/sysroot)
#     --abi ABI         download only one ABI (default: all four)
#     --repo OWNER/REPO GitHub repo (default: nordstjernen-web/nordstjernen-android)
#     --run-id ID       download artifacts from a specific workflow run
#                       (default: latest successful run on the default branch)
#     --branch NAME     branch to pick the latest run from (default: main)
#
# Requires the GitHub CLI (`gh`, authenticated) which knows how to fetch
# Actions artifacts. Install: https://cli.github.com/

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO="nordstjernen-web/nordstjernen-android"
WORKFLOW="build-deps.yml"
SYSROOT_BASE="${NORDSTJERNEN_ANDROID_SYSROOT:-${ANDROID_DIR}/sysroot}"
ABIS=("${ALL_ABIS[@]}")
RUN_ID=""
BRANCH="main"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sysroot) SYSROOT_BASE="$2"; shift 2 ;;
    --abi)     ABIS=("$2"); shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --run-id)  RUN_ID="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "the GitHub CLI 'gh' is required (https://cli.github.com/)"

if [ -z "${RUN_ID}" ]; then
  log "Resolving latest successful '${WORKFLOW}' run on ${REPO}@${BRANCH}"
  RUN_ID="$(gh run list --repo "${REPO}" --workflow "${WORKFLOW}" \
            --branch "${BRANCH}" --status success --limit 1 \
            --json databaseId --jq '.[0].databaseId')"
  [ -n "${RUN_ID}" ] && [ "${RUN_ID}" != "null" ] || die "no successful run found"
fi
log "Using workflow run ${RUN_ID}"

mkdir -p "${SYSROOT_BASE}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

for abi in "${ABIS[@]}"; do
  is_valid_abi "${abi}" || die "invalid ABI: ${abi}"
  local_art="nordstjernen-android-sysroot-${abi}"
  log "Downloading artifact ${local_art}"
  rm -rf "${tmp:?}/${abi}"; mkdir -p "${tmp}/${abi}"
  gh run download "${RUN_ID}" --repo "${REPO}" \
    --name "${local_art}" --dir "${tmp}/${abi}"

  # Artifact contains a top-level <abi>/ dir; sync it into the sysroot base.
  if [ -d "${tmp}/${abi}/${abi}" ]; then
    rm -rf "${SYSROOT_BASE:?}/${abi}"
    mkdir -p "${SYSROOT_BASE}/${abi}"
    cp -a "${tmp}/${abi}/${abi}/." "${SYSROOT_BASE}/${abi}/"
  else
    # Fallback: artifact was flattened; copy its contents directly.
    rm -rf "${SYSROOT_BASE:?}/${abi}"
    mkdir -p "${SYSROOT_BASE}/${abi}"
    cp -a "${tmp}/${abi}/." "${SYSROOT_BASE}/${abi}/"
  fi
  log "Installed ${abi} -> ${SYSROOT_BASE}/${abi}"
done

cat >&2 <<EOF

Prebuilt sysroot ready. Point the engine build at it with:

    export NORDSTJERNEN_ANDROID_SYSROOT="${SYSROOT_BASE}"

then run android/scripts/build-deps.sh as usual; it will pick up the prebuilt
libraries under \$NORDSTJERNEN_ANDROID_SYSROOT/<abi> instead of compiling them.
EOF
