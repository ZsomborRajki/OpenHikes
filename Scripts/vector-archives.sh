#!/bin/bash
#
# vector-archives.sh — publish which archives the OpenHikes map is drawn from.
#
# The app draws the OpenStreetMap style from a basemap archive and an extras
# archive on tiles.openhikes.app, and learns which from the server's manifest,
# `manifest.json` at its root (`VectorTileArchiveManifest`). That manifest is
# OpenHikes/Tiles/Vector/VectorTileArchiveManifest.json: the app bundles it,
# and this puts it on the server. To move the map to a new build, upload the
# archive (`Scripts/vector-extras.sh upload`, or a Protomaps build copied into
# the bucket), put its name at the head of its list, raise `revision`, run
# `publish`, and commit the file.
#
# `check` asks the server for every archive the manifest names, and fails on
# any it does not have: an app told to draw from one would fall back to
# openstreetmap.org. `publish` checks, refuses a revision no higher than the
# server's (an app never moves to a lower one), puts the file in the R2 bucket
# as `manifest.json`, and reads it back through the server. It signs with
# R2's S3 keys, as vector-extras.sh does, read from OPENHIKES_R2_ENV (default
# ~/.config/openhikes/r2-openhikes-tiles.env).
#
# An archive leaves the manifest before it leaves the bucket, and stays in the
# bucket for a while after, for apps that have not read the manifest since:
# one that asks for a deleted archive gets a 410, reads the manifest again and
# moves, but a build from before the manifest existed never moves at all.
#
# It is a development tool and is in no gate.
#
# Usage:
#   Scripts/vector-archives.sh check
#   Scripts/vector-archives.sh publish
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${OPENHIKES_VECTOR_ARCHIVE_MANIFEST:-$REPO_ROOT/OpenHikes/Tiles/Vector/VectorTileArchiveManifest.json}"
SERVER="${OPENHIKES_TILE_SERVER:-https://tiles.openhikes.app}"
SCRATCH=""

usage() {
  echo "usage: Scripts/vector-archives.sh check" >&2
  echo "       Scripts/vector-archives.sh publish" >&2
  exit 2
}

die() {
  echo "vector-archives: $*" >&2
  exit 1
}

cleanup() {
  [[ -z "$SCRATCH" ]] || rm -f "$SCRATCH"
}
trap cleanup EXIT

# One value of a JSON file, by key path (`basemaps.0.name`); an array's count.
value() {
  plutil -extract "$1" raw -o - "$2" 2>/dev/null
}

check() {
  [[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST"
  [[ "$(value version "$MANIFEST")" == 1 ]] || die "$MANIFEST is not a version 1 manifest"
  [[ "$(value revision "$MANIFEST")" =~ ^[1-9][0-9]*$ ]] || die "$MANIFEST has no revision"
  local names=() list count index name
  for list in basemaps extras; do
    count="$(value "$list" "$MANIFEST")" || die "$MANIFEST has no $list"
    for (( index = 0; index < count; index++ )); do
      name="$(value "$list.$index.name" "$MANIFEST")" || die "$list $index in $MANIFEST has no name"
      [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "'$name' is not a name the app reads"
      names+=("$name")
    done
  done
  (( $(value basemaps "$MANIFEST") > 0 )) || die "$MANIFEST names no basemap"
  local status missing=0
  for name in "${names[@]}"; do
    status="$(curl -s -o /dev/null -w "%{http_code}" "$SERVER/$name.json")"
    if [[ "$status" == 200 ]]; then
      echo "vector-archives: $SERVER has $name"
    else
      echo "vector-archives: $SERVER answered $status for $name" >&2
      missing=1
    fi
  done
  (( missing == 0 )) || die "upload every archive the manifest names before publishing it"
}

publish() {
  check
  local env_file="${OPENHIKES_R2_ENV:-$HOME/.config/openhikes/r2-openhikes-tiles.env}"
  [[ -f "$env_file" ]] || die "no R2 keys at $env_file"
  # shellcheck disable=SC1090
  set -a; . "$env_file"; set +a
  local revision live_revision status
  revision="$(value revision "$MANIFEST")"
  SCRATCH="$(mktemp)"
  status="$(curl -s -o "$SCRATCH" -w "%{http_code}" "$SERVER/manifest.json")"
  case "$status" in
    200)
      if cmp -s "$MANIFEST" "$SCRATCH"; then
        echo "vector-archives: $SERVER already has revision $revision"
        return
      fi
      live_revision="$(value revision "$SCRATCH")" || die "the manifest on $SERVER has no revision"
      (( revision > live_revision )) \
        || die "revision $revision is not above $live_revision, which $SERVER has; raise it"
      ;;
    404) ;;
    *) die "$SERVER answered $status for manifest.json" ;;
  esac
  local url="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET/manifest.json"
  local signing=(--aws-sigv4 "aws:amz:auto:s3" --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY"
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD")
  status="$(curl -s -o /dev/null -w "%{http_code}" "${signing[@]}" \
    -H "Content-Type: application/json" -T "$MANIFEST" "$url")"
  [[ "$status" == 200 ]] || die "R2 answered $status to the upload"
  status="$(curl -s -o "$SCRATCH" -w "%{http_code}" "$SERVER/manifest.json")"
  [[ "$status" == 200 ]] && cmp -s "$MANIFEST" "$SCRATCH" \
    || die "uploaded, but $SERVER does not serve it back ($status)"
  echo "vector-archives: published revision $revision to $SERVER"
}

[[ $# -eq 1 ]] || usage
case "$1" in
  check) check ;;
  publish) publish ;;
  *) usage ;;
esac
