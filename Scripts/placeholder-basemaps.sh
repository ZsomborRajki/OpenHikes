#!/bin/bash
#
# placeholder-basemaps.sh — re-render the map the widget gallery draws.
#
# The widget's gallery entry and its Xcode previews show a trail that does not
# exist, so there is nothing in the App Group for `TrailBasemapRenderer` to
# have rendered and `TrailMapView` falls all the way back to the line glyph: a
# hiker choosing the widget sees a squiggle where a real trail shows a map.
# This renders the placeholder's four basemaps ahead of time — the two shapes
# and the two appearances, exactly the set the renderer produces — and checks
# them into the widget's asset catalogue, where `TrailWidgetPlaceholderBasemaps`
# reads them back through the `imageData:` seam `TrailMapView` already has for
# previews and tests.
#
# It is a *development* tool and is in no gate. Re-run it when the placeholder
# route in `TrailWidgetPlaceholder.swift` moves — `placeholderBasemapsFrameTheTrail`
# in `OpenWidgetTests` is what fails and says so — or to pick up a change in
# how Apple draws a muted map. It needs a network connection, because
# MKMapSnapshotter fetches its own tiles.
#
# Usage:
#   Scripts/placeholder-basemaps.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$REPO_ROOT/OpenWidget/Assets.xcassets"
MANIFEST="$REPO_ROOT/OpenWidget/TrailWidgetPlaceholderBasemaps.swift"

# The placeholder route, as `TrailWidgetPlaceholder.swift` spells it. Passed in
# rather than imported because that file lives in the widget target, which a
# command-line tool cannot link against. The two are held together by the test
# named above rather than by anyone remembering, which is the only arrangement
# that survives.
POLYLINE="47.5860,12.9880 47.5895,12.9955 47.5925,13.0035 47.5958,13.0112 47.5985,13.0175"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Sources/RenderPlaceholder"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RenderPlaceholder",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "$REPO_ROOT/OpenHikesShared")],
    targets: [
        .executableTarget(
            name: "RenderPlaceholder",
            dependencies: [.product(name: "OpenHikesShared", package: "OpenHikesShared")]
        ),
    ]
)
EOF

cp "$REPO_ROOT/Scripts/lib/render-placeholder-basemaps.swift" \
   "$WORK/Sources/RenderPlaceholder/main.swift"

echo "Rendering four basemaps (this needs the network) …"
swift run --package-path "$WORK" RenderPlaceholder \
    --assets "$ASSETS" \
    --manifest "$MANIFEST" \
    --polyline $POLYLINE

echo "Wrote $MANIFEST and four data sets under $ASSETS"
