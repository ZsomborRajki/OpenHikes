#!/bin/bash
#
# vector-extras.sh — build the vector extras from the planet.
#
# The OpenStreetMap style draws the Protomaps basemap on tiles.openhikes.app,
# which leaves out much of what OpenStreetMap Carto draws: car parks mapped
# as areas with no name, barriers, towers and crosses, offices, the type of
# an information point and the goods of a vending machine, waterfalls,
# one-way ways in their own direction, the size of each named area, the
# ground it has no kind for (scree, heath, quarries, vineyards), parks and
# protected areas, lifts and their stations, power lines with their towers,
# every path, track and service road with what Carto draws it by, the roads
# being built, dams and ridges,
# cliffs in their own direction, trees, the water that is not always there,
# what picks the symbols of a wood or a wetland, the names of buildings, and
# the huts, stations and summits Carto shows before the basemap has them.
# The extras are those, as a second PMTiles archive the app draws into the
# basemap's tiles (`VectorTileSource.extras`).
#
# It cuts the planet down with `osmium tags-filter` and
# Scripts/lib/vector-extras.filter, and the named areas and buildings with
# Scripts/lib/vector-extras-areas.filter and a second cut for a name, then
# builds the archive with Planetiler from Scripts/lib/vector-extras.yml. Bring the planet up to date first with
# `Scripts/trail-cells.sh update-planet`. The archive is named for the day and
# the hour (UTC) the planet is current to, `extras-YYYYMMDD-HH.pmtiles`, so a
# second build on one day goes up under a name of its own.
#
# `upload` puts it under that name in the R2 bucket `openhikes-tiles`, beside
# the basemap, and refuses a name already there: the tile server's cache keeps
# a tile for a day, so a file replaced in place would mix two builds. It asks
# first, so a name already taken costs no upload, and then sends the file in
# parts, completed on condition that nothing is there (`If-None-Match: *`),
# which R2 checks as the write commits: of two uploads to one name that both
# found it free, the second is refused rather than written over the first.
# Then name it in the app's manifest and publish that
# (`Scripts/vector-archives.sh use`, then `publish`). It signs with R2's S3
# keys, read from OPENHIKES_R2_ENV (default
# ~/.config/openhikes/r2-openhikes-tiles.env: R2_ACCOUNT_ID, R2_ACCESS_KEY_ID,
# R2_SECRET_ACCESS_KEY, R2_BUCKET), no faster than OPENHIKES_R2_MIB_PER_SECOND
# MiB a second where that is set (Scripts/lib/r2.sh).
#
# It is a development tool and is in no gate. It needs osmium and Planetiler
# (`brew install osmium-tool planetiler`). On an M4 Max the planet took 35
# minutes to cut, and the cut's 14.6 GB eleven minutes to build into 16.1 GB.
# The buildings and the areas of the named areas' kinds, named or not, pass
# through the work directory on the way: 48 GB of the planet, of which the
# named are 3.6 GB.
#
# Usage:
#   Scripts/vector-extras.sh build <planet.osm.pbf> [<work-dir>]
#   Scripts/vector-extras.sh upload <extras-YYYYMMDD-HH.pmtiles>
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: Scripts/vector-extras.sh build <planet.osm.pbf> [<work-dir>]" >&2
  echo "       Scripts/vector-extras.sh upload <extras-YYYYMMDD-HH.pmtiles>" >&2
  exit 2
}

# shellcheck source=lib/r2.sh
source "$REPO_ROOT/Scripts/lib/r2.sh"

die() {
  echo "vector-extras: $*" >&2
  exit 1
}

# The extras passed the 5 GiB R2 takes in one request with extras-20261119-18,
# so they go up in parts of 256 MiB: some sixty for 16 GB, eight of them on
# disk at a time.
upload() {
  local archive="$1" key existing
  [[ -f "$archive" ]] || die "no archive at $archive"
  r2_load_keys
  key="$(basename "$archive")"
  existing="$(r2_etag "$key")"
  [[ -z "$existing" ]] || die "$key is already in $R2_BUCKET; build from a newer planet"
  r2_put_parts "$archive" "$key" 256
  echo "vector-extras: next, Scripts/vector-archives.sh use ${key%.pmtiles}"
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

# The hour the planet is current to, from the replication timestamp pyosmium
# writes into its header.
STAMP="$(osmium fileinfo --get header.option.osmosis_replication_timestamp "$PLANET")"
[[ "$STAMP" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}) ]] || {
  echo "vector-extras: the planet's header has no replication timestamp" >&2
  exit 1
}
NAME="extras-${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}-${BASH_REMATCH[4]}"
mkdir -p "$WORK"
# Planetiler's scratch files go in a directory this build makes for itself,
# and only that one is removed, however the build ends: a work directory
# passed in can hold a `tmp` of its own, or be another build's.
SCRATCH="$(mktemp -d "$WORK/tmp.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

osmium tags-filter "$PLANET" \
  --expressions="$REPO_ROOT/Scripts/lib/vector-extras.filter" \
  --output="$SCRATCH/points.osm.pbf" --overwrite
# The named areas and buildings: every area of the kinds whose names the
# extras keep and every building, then the named ones among them, which
# osmium cannot ask for in one pass.
osmium tags-filter "$PLANET" \
  --expressions="$REPO_ROOT/Scripts/lib/vector-extras-areas.filter" \
  --output="$SCRATCH/areas.osm.pbf" --overwrite
osmium tags-filter "$SCRATCH/areas.osm.pbf" wr/name \
  --output="$SCRATCH/named-areas.osm.pbf" --overwrite
rm "$SCRATCH/areas.osm.pbf"
osmium merge "$SCRATCH/points.osm.pbf" "$SCRATCH/named-areas.osm.pbf" \
  --output="$WORK/extras.osm.pbf" --overwrite

planetiler generate-custom \
  --schema="$REPO_ROOT/Scripts/lib/vector-extras.yml" \
  --osm_path="$WORK/extras.osm.pbf" \
  --output="$WORK/$NAME.pmtiles" \
  --maxzoom=15 --render_maxzoom=15 \
  --tmpdir="$SCRATCH" --download_dir="$WORK/sources" \
  --force

echo "vector-extras: built $WORK/$NAME.pmtiles"
