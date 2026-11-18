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
# the planet is current to, `extras-YYYYMMDD.pmtiles`. Upload it under that
# name to the R2 bucket `openhikes-tiles`, beside the basemap and never over
# an earlier one, then point `VectorTileSource.openHikesPlanet` at it.
#
# It is a development tool and is in no gate. It needs osmium and Planetiler
# (`brew install osmium-tool planetiler`). On an M4 Max the planet took seven
# minutes to filter, and the filtered 2.4 GB a few minutes to build.
#
# Usage:
#   Scripts/vector-extras.sh <planet.osm.pbf> [<work-dir>]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: Scripts/vector-extras.sh <planet.osm.pbf> [<work-dir>]" >&2
  exit 2
fi
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
