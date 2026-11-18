#!/bin/bash
#
# vector-extras.sh — build the vector extras from the planet.
#
# The OpenStreetMap style draws the Protomaps basemap on tiles.openhikes.app,
# which leaves out much of what OpenStreetMap Carto draws: car parks mapped
# as areas with no name, barriers, towers and crosses, offices, the type of
# an information point and the goods of a vending machine, waterfalls. The
# extras are those, as a second PMTiles archive the app draws into the
# basemap's tiles (`VectorTileSource.extras`).
#
# It cuts the planet down with `osmium tags-filter` and
# Scripts/lib/vector-extras.filter, then builds the archive with Planetiler
# from Scripts/lib/vector-extras.yml. Bring the planet up to date first with
# `Scripts/trail-cells.sh update-planet`. The archive is named for the date
# the planet is current to, `extras-YYYYMMDD.pmtiles`.
#
# `upload` puts it under that name in the R2 bucket `openhikes-tiles`, beside
# the basemap, and refuses a name already there: the tile server's cache keeps
# a tile for a day, so a file replaced in place would mix two builds. Then
# point `VectorTileSource.openHikesPlanet` at it. It signs with R2's S3 keys,
# read from OPENHIKES_R2_ENV (default ~/.config/openhikes/r2-openhikes-tiles.env:
# R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET), and sends
# the file in one request, which R2 takes up to 5 GiB.
#
# It is a development tool and is in no gate. It needs osmium and Planetiler
# (`brew install osmium-tool planetiler`). On an M4 Max the planet took seven
# minutes to filter, and the filtered 2.4 GB a minute and a quarter to build
# into 1.8 GB.
#
# Usage:
#   Scripts/vector-extras.sh build <planet.osm.pbf> [<work-dir>]
#   Scripts/vector-extras.sh upload <extras-YYYYMMDD.pmtiles>
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: Scripts/vector-extras.sh build <planet.osm.pbf> [<work-dir>]" >&2
  echo "       Scripts/vector-extras.sh upload <extras-YYYYMMDD.pmtiles>" >&2
  exit 2
}

upload() {
  local archive="$1"
  local env_file="${OPENHIKES_R2_ENV:-$HOME/.config/openhikes/r2-openhikes-tiles.env}"
  [[ -f "$archive" ]] || { echo "vector-extras: no archive at $archive" >&2; exit 1; }
  [[ -f "$env_file" ]] || { echo "vector-extras: no R2 keys at $env_file" >&2; exit 1; }
  # shellcheck disable=SC1090
  set -a; . "$env_file"; set +a
  local key
  key="$(basename "$archive")"
  local size
  size="$(stat -f %z "$archive")"
  if (( size > 5 * 1024 * 1024 * 1024 )); then
    echo "vector-extras: $key is over the 5 GiB R2 takes in one request" >&2
    exit 1
  fi
  local url="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com/$R2_BUCKET/$key"
  local signing=(--aws-sigv4 "aws:amz:auto:s3" --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY"
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD")
  local existing
  existing="$(curl -s -o /dev/null -w "%{http_code}" -I "${signing[@]}" "$url")"
  case "$existing" in
    404) ;;
    200) echo "vector-extras: $key is already in $R2_BUCKET; build under a new date" >&2; exit 1 ;;
    *) echo "vector-extras: R2 answered $existing when asked for $key" >&2; exit 1 ;;
  esac
  local status
  status="$(curl -s -o /dev/null -w "%{http_code}" "${signing[@]}" \
    -H "Content-Type: application/octet-stream" -T "$archive" "$url")"
  [[ "$status" == 200 ]] || { echo "vector-extras: R2 answered $status to the upload" >&2; exit 1; }
  echo "vector-extras: uploaded $key ($size bytes) to $R2_BUCKET"
}

[[ $# -ge 1 ]] || usage
COMMAND="$1"
shift
case "$COMMAND" in
  upload)
    [[ $# -eq 1 ]] || usage
    upload "$1"
    exit 0
    ;;
  build)
    [[ $# -ge 1 && $# -le 2 ]] || usage
    ;;
  *) usage ;;
esac
PLANET="$1"
WORK="${2:-$HOME/Library/Caches/OpenHikes/vector-extras}"
[[ -f "$PLANET" ]] || { echo "vector-extras: no planet at $PLANET" >&2; exit 1; }
for tool in osmium planetiler; do
  command -v "$tool" >/dev/null || { echo "vector-extras: $tool is not installed" >&2; exit 1; }
done

# The date the planet is current to, from the replication timestamp
# pyosmium writes into its header.
STAMP="$(osmium fileinfo --get header.option.osmosis_replication_timestamp "$PLANET")"
[[ "$STAMP" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T ]] || {
  echo "vector-extras: the planet's header has no replication timestamp" >&2
  exit 1
}
NAME="extras-${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
mkdir -p "$WORK"

osmium tags-filter "$PLANET" \
  --expressions="$REPO_ROOT/Scripts/lib/vector-extras.filter" \
  --output="$WORK/extras.osm.pbf" --overwrite

planetiler generate-custom \
  --schema="$REPO_ROOT/Scripts/lib/vector-extras.yml" \
  --osm_path="$WORK/extras.osm.pbf" \
  --output="$WORK/$NAME.pmtiles" \
  --maxzoom=15 --render_maxzoom=15 \
  --tmpdir="$WORK/tmp" --download_dir="$WORK/sources" \
  --force

rm -rf "$WORK/tmp"
echo "vector-extras: built $WORK/$NAME.pmtiles"
