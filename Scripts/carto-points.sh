#!/bin/bash
#
# carto-points.sh — rebuild the table of points the vector map draws.
#
# The OpenStreetMap style's points — every icon, its color and the zoom it
# appears at, and the name written under it — are OpenStreetMap Carto's, the
# style tile.openstreetmap.org draws. This reads them out of a pinned Carto
# release with Scripts/lib/carto-points.swift and writes the table the app
# reads (OpenHikes/Tiles/Vector/VectorTilePoints.json) and the icons it names
# (OpenHikes/Tiles/Vector/CartoIcons.xcassets, replaced whole). Carto's style
# and icons are CC0.
#
# It is a *development* tool and is in no gate. Re-run it to move to a newer
# Carto release: change CARTO_VERSION, run, and read the diff of the table.
# It needs a network connection, for the release's tarball.
#
# Usage:
#   Scripts/carto-points.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARTO_VERSION="v6.1.0"
VECTOR="$REPO_ROOT/OpenHikes/Tiles/Vector"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/carto"
curl --fail --silent --show-error --location \
  "https://github.com/gravitystorm/openstreetmap-carto/archive/refs/tags/$CARTO_VERSION.tar.gz" \
  | tar -xz -C "$WORK/carto" --strip-components=1

# Compiled rather than run as a script: evaluating every kind again for each
# range of an area's size takes minutes compiled, and many times that
# interpreted.
xcrun swiftc -O -o "$WORK/carto-points" "$REPO_ROOT/Scripts/lib/carto-points.swift"
CARTO_VERSION="$CARTO_VERSION" "$WORK/carto-points" \
  "$WORK/carto" "$VECTOR/VectorTilePoints.json" "$VECTOR/CartoIcons.xcassets"
