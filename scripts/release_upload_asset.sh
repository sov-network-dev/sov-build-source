#!/usr/bin/env bash
# release_upload_asset.sh — put one built file onto a GitHub Release, idempotently.
#
#   release_upload_asset.sh <tag> <file> [replace]
#
# Used by every platform job in .github/workflows/release.yml. The release itself is
# created (as a DRAFT, when the tag is new) by the workflow's `prepare` job, so this
# script only ever adds to something that exists. Release binaries deliberately do NOT
# travel through Actions artifacts any more: the free tier's artifact quota is 500 MB,
# a single APK is ~160 MB, and GitHub re-counts usage only every 6-12 hours -- which
# turned three fully successful desktop builds into "failed" jobs on 2026-09-22.
#
# Idempotent on purpose: if the asset is already on the release it is left alone unless
# `replace` is passed, so re-running the workflow to ADD a platform cannot silently swap
# out a file citizens have already downloaded and checksummed.
set -euo pipefail
TAG="$1"; FILE="$2"; REPLACE="${3:-false}"
: "${RELEASE_REPO:?RELEASE_REPO must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
[ -s "$FILE" ] || { echo "::error::$FILE is missing or empty"; exit 1; }
NAME="$(basename "$FILE")"

existing="$(gh release view "$TAG" --repo "$RELEASE_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)"
if printf '%s\n' "$existing" | grep -qx "$NAME"; then
  if [ "$REPLACE" = "true" ]; then
    echo "$NAME already on $TAG -- replacing (replace_existing=true)"
    gh release upload "$TAG" "$FILE" --repo "$RELEASE_REPO" --clobber
  else
    echo "$NAME already on $TAG -- left untouched (pass replace_existing=true to overwrite)"
    exit 0
  fi
else
  gh release upload "$TAG" "$FILE" --repo "$RELEASE_REPO"
fi
echo "uploaded $NAME ($(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE") bytes) -> $RELEASE_REPO@$TAG"
