//
//  VectorTileLineLabels+Areas.swift
//  OpenHikes
//
//  A protected area's name along the inside of its edge, as OpenStreetMap
//  Carto writes a national park's, a nature reserve's or aboriginal lands'
//  from zoom 13 once the area covers 192,000 square pixels
//  (`protected-areas-text` in `admin.mss`): in the green of its border, or
//  the brown of aboriginal lands', 10 pixels inside the edge, and about every
//  750 pixels along it. The name stays on the area's side of the edge however
//  it reads, so two areas that share an edge are named on either side of it.
//  Carto spaces the names along the whole edge, which no tile here sees, so a
//  name stands where the edge crosses a grid laid over the world 750 pixels
//  apart, as a road's number does (`VectorTileShields`): the tiles on either
//  side of an edge between two agree on where the names go.
//
//  Near a corner of the grid an edge crosses a line down it and a line across
//  it close together, and two tiles either side of a seam would each name
//  the crossing on their side, nearer each other than Carto's 250 pixels.
//  So a crossing of a line across gives way to a crossing of a line down
//  near it along the edge. A tile sees only its own stretch of the edge, so
//  past the ends of that stretch it takes the edge to run straight on, as the
//  tile beside it sees it do.
//
//  The vector extras' `protected_areas` layer gives an area its size and its
//  names from zoom 13 where it is that large by then, and every area its own
//  at zoom 14, the deepest zoom every offline download holds. So the size is
//  read again at each zoom drawn: at the archive's zooms, and at those drawn
//  deeper than it goes.
//
//  The archive cuts an area along a square its buffer outside its tile, and
//  that cut is no edge of the area, so a ring's sides along the cut are not
//  named. The rest of the ring is, the buffer's stretch too: an edge just
//  outside the tile has its name 10 pixels inside it, where the tile the edge
//  runs in has no room to set it. A ring keeps the archive's winding, which
//  puts the area on its right as it runs, the side the name goes.
//
//  An edge that follows field boundaries turns sharper from letter to letter
//  than a name may bend, so most of the tiles an edge crosses fit no name.
//  Mapnik refuses those the same way.
//

import Algorithms
import CoreGraphics
import Foundation

nonisolated extension VectorTileLineLabels {
    /// Carto names a protected area along its edge from this zoom.
    static let areaEdgeZ = 13
    /// The zoom the extras give every protected area its size and its names
    /// at, however small: the deepest zoom every offline download holds,
    /// which the map draws each deeper zoom from where it has no zoom 15.
    static let areaEdgeEveryAreaZ = 14
    /// The least size of an area named along its edge, in the square pixels
    /// of a 256-pixel tile at the zoom drawn: Carto's `way_pixels`.
    static let areaEdgeSize: Double = 192_000
    /// How far outside its tile the archive cuts a protected area, in the
    /// pixels of a 256-pixel tile: the extras' `buffer` for the layer.
    static let areaEdgeBuffer: CGFloat = 8
    /// The extras' kind for aboriginal lands, whose border and name are
    /// brown where every other protected area's are green.
    static let aboriginalLandsKind = "aboriginal_lands"

    /// The edges of the protected areas `tile` names at `target`'s zoom: the
    /// stretches of each large enough area's rings between the archive's
    /// cuts, each running as its ring does.
    static func areaEdges(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress,
        language: String
    ) -> [NamedLine] {
        guard target.z >= areaEdgeZ, let layer = tile.layers[VectorTileRasterizer.protectedAreasLayer] else {
            return []
        }
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        let buffer = geometry.frame.width * areaEdgeBuffer / VectorTileRasterizer.styleTileSize
        let cut = geometry.frame.insetBy(dx: -buffer, dy: -buffer)
        let scale = pow(4, Double(target.z))
        return layer.features.flatMap { feature -> [NamedLine] in
            guard feature.type == .polygon,
                  let size = feature.number(VectorTilePoints.sizeKey),
                  size * scale > areaEdgeSize,
                  let name = VectorTileLabels.name(of: feature, language: language)
            else { return [] }
            let category: VectorTileLabelStyle.LineCategory = feature.string("kind") == aboriginalLandsKind
                ? .aboriginalLands
                : .protectedArea
            return geometry.lines(of: feature).flatMap { ring in
                // Half a step of the archive's grid: the cut lies on it.
                stretches(of: ring, cutAlong: cut, within: geometry.scale / 2).map { points in
                    NamedLine(category: category, name: name, points: points)
                }
            }
        }
    }

    /// Where along `path` a name `width` wide is tried, on a line each tile
    /// sees only a stretch of: where it crosses a line of a grid laid over
    /// the whole world, `spacing` apart, with `origin` the picture's corner
    /// on it (``edgeCrossings(of:origin:every:clearance:)``). Each mark may
    /// slide by `step` either way, no further than a quarter of `spacing`,
    /// and only as far as the name stays on the line. Marks stand far enough
    /// apart along the line that two names at neighbouring marks stand at
    /// least `apart` from each other however each slid, in the same tile or
    /// on either side of a seam.
    static func marks(
        along path: MeasuredPath,
        origin: CGPoint,
        every spacing: CGFloat,
        apart: CGFloat,
        width: CGFloat,
        step: CGFloat
    ) -> [Mark] {
        guard width <= path.length, spacing > 0, step > 0 else { return [] }
        let reach = spacing / 4
        let slides = slides(by: step, upTo: reach)
        let fits = (width / 2)...(path.length - width / 2)
        let crossings = edgeCrossings(of: path.points, origin: origin, every: spacing, clearance: apart + 2 * reach)
        return crossings.compactMap { crossing in
            let spots = slides.map { crossing + $0 }.filter(fits.contains)
            return spots.isEmpty ? nil : Mark(distance: crossing, spots: spots)
        }
    }

    /// How far along `points` the line crosses the world's grid, `spacing`
    /// apart with `origin` the picture's corner on it: wherever it crosses a
    /// line down the map, and where it crosses a line across the map no
    /// nearer than `clearance` along it to a line down. Past its first and
    /// last points the line is taken to run straight on, so a tile that sees
    /// only its own stretch of an edge gives way to a crossing just beyond
    /// it, as the tile that holds that crossing names it.
    static func edgeCrossings(
        of points: [CGPoint],
        origin: CGPoint,
        every spacing: CGFloat,
        clearance: CGFloat
    ) -> [CGFloat] {
        let sides = points.adjacentPairs().filter { $0.0 != $0.1 }
        guard let first = sides.first, let last = sides.last else { return [] }
        let before = point(from: first.1, through: first.0, on: clearance)
        let after = point(from: last.0, through: last.1, on: clearance)
        let length = Self.length(of: points)
        let crossings = VectorTileShields.gridCrossings(of: [before] + points + [after], origin: origin, every: spacing)
            .map { VectorTileShields.GridCrossing(distance: $0.distance - clearance, isDown: $0.isDown) }
        let downs = crossings.filter(\.isDown).map(\.distance)
        return crossings.filter { crossing in
            guard crossing.distance >= 0, crossing.distance < length else { return false }
            return crossing.isDown || !downs.contains { abs($0 - crossing.distance) < clearance }
        }
        .map(\.distance)
    }

    /// How far a name may slide from its mark, nearest first: not at all,
    /// then `step` either way, and on by `step` as far as `reach`.
    static func slides(by step: CGFloat, upTo reach: CGFloat) -> [CGFloat] {
        stride(from: step, through: reach, by: step).reduce(into: [0]) { slides, slide in
            slides += [slide, -slide]
        }
    }

    /// The stretches of the closed `ring` between the sides along the
    /// archive's `cut`, a square around its tile, each running as the ring
    /// does: a side lies along the cut where both its ends lie on one of the
    /// square's sides, `within` the arithmetic's error. A stretch that runs
    /// on across the ring's first point is one stretch, and a ring the cut
    /// leaves whole is one stretch back to its start.
    static func stretches(of ring: [CGPoint], cutAlong cut: CGRect, within tolerance: CGFloat) -> [[CGPoint]] {
        guard let start = ring.first, ring.count > 2 else { return [] }
        var stretches: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (from, to) in (ring + [start]).adjacentPairs() {
            if runs(from: from, to: to, along: cut, within: tolerance) {
                if current.count > 1 { stretches.append(current) }
                current = []
            } else {
                if current.isEmpty { current = [from] }
                current.append(to)
            }
        }
        if current.count > 1 { stretches.append(current) }
        if stretches.count > 1, let last = stretches.last, last.last == stretches[0].first {
            stretches[0] = last + stretches[0].dropFirst()
            stretches.removeLast()
        }
        return stretches
    }

    /// Whether the side from `from` to `to` lies along one of `cut`'s sides.
    private static func runs(from: CGPoint, to: CGPoint, along cut: CGRect, within tolerance: CGFloat) -> Bool {
        let lines: [(CGFloat, CGFloat, CGFloat)] = [
            (from.x, to.x, cut.minX), (from.x, to.x, cut.maxX),
            (from.y, to.y, cut.minY), (from.y, to.y, cut.maxY),
        ]
        return lines.contains { from, to, line in abs(from - line) <= tolerance && abs(to - line) <= tolerance }
    }

    /// The point `distance` on from `end` along the straight line from
    /// `start` through it.
    private static func point(from start: CGPoint, through end: CGPoint, on distance: CGFloat) -> CGPoint {
        let run = hypot(end.x - start.x, end.y - start.y)
        return CGPoint(
            x: end.x + (end.x - start.x) / run * distance,
            y: end.y + (end.y - start.y) / run * distance
        )
    }
}
