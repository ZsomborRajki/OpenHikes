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
//  The vector extras' `protected_areas` layer gives an area its size and its
//  names from the first zoom it is that large, and every area its own at
//  zoom 15, so the size is read again at each zoom drawn: at the archive's
//  zooms, and at those drawn deeper than it goes.
//
//  The archive cuts an area at its tile, a little outside the tile, and that
//  cut is no edge of the area, so only the stretches of each ring inside the
//  archive's tile are named. A ring keeps the archive's winding, which puts
//  the area on its right as it runs, the side the name goes.
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
    /// The least size of an area named along its edge, in the square pixels
    /// of a 256-pixel tile at the zoom drawn: Carto's `way_pixels`.
    static let areaEdgeSize: Double = 192_000
    /// The extras' kind for aboriginal lands, whose border and name are
    /// brown where every other protected area's are green.
    static let aboriginalLandsKind = "aboriginal_lands"

    /// The edges of the protected areas `tile` names at `target`'s zoom: the
    /// stretches of each large enough area's rings inside the archive's
    /// tile, each running as its ring does.
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
                stretches(of: ring, inside: geometry.frame).map { points in
                    NamedLine(category: category, name: name, points: points)
                }
            }
        }
    }

    /// Where along `path` a name `width` wide is tried, on a line each tile
    /// sees only a stretch of: wherever it crosses a line of a grid laid
    /// over the whole world, `spacing` apart, with `origin` the picture's
    /// corner on it. Each mark may slide by `step` either way, no further
    /// than a quarter of `spacing`, and only as far as the name stays on the
    /// line.
    static func marks(
        along path: MeasuredPath,
        origin: CGPoint,
        every spacing: CGFloat,
        width: CGFloat,
        step: CGFloat
    ) -> [Mark] {
        guard width <= path.length, spacing > 0, step > 0 else { return [] }
        let slides = slides(by: step, upTo: spacing / 4)
        let fits = (width / 2)...(path.length - width / 2)
        return VectorTileShields.crossings(of: path.points, origin: origin, every: spacing).compactMap { crossing in
            let spots = slides.map { crossing + $0 }.filter(fits.contains)
            return spots.isEmpty ? nil : Mark(distance: crossing, spots: spots)
        }
    }

    /// How far a name may slide from its mark, nearest first: not at all,
    /// then `step` either way, and on by `step` as far as `reach`.
    static func slides(by step: CGFloat, upTo reach: CGFloat) -> [CGFloat] {
        stride(from: step, through: reach, by: step).reduce(into: [0]) { slides, slide in
            slides += [slide, -slide]
        }
    }

    /// The stretches of the closed `ring` inside `frame`, each running as
    /// the ring does: one that runs on across the ring's first point is one
    /// stretch, and a ring wholly inside is one stretch back to its start.
    static func stretches(of ring: [CGPoint], inside frame: CGRect) -> [[CGPoint]] {
        guard let start = ring.first, ring.count > 2 else { return [] }
        var stretches: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (from, to) in (ring + [start]).adjacentPairs() {
            guard let part = part(from: from, to: to, inside: frame) else {
                if current.count > 1 { stretches.append(current) }
                current = []
                continue
            }
            // A side that comes back into the frame starts a stretch.
            if current.last != part.entry {
                if current.count > 1 { stretches.append(current) }
                current = [part.entry]
            }
            current.append(part.exit)
        }
        if current.count > 1 { stretches.append(current) }
        if stretches.count > 1, let last = stretches.last, last.last == stretches[0].first {
            stretches[0] = last + stretches[0].dropFirst()
            stretches.removeLast()
        }
        return stretches
    }

    /// Where the side from `from` to `to` runs inside `frame`: the whole
    /// side, or the part between where it comes in and where it goes out.
    /// `nil` where it misses the frame or only touches it.
    private static func part(
        from: CGPoint,
        to: CGPoint,
        inside frame: CGRect
    ) -> (entry: CGPoint, exit: CGPoint)? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        var enters: CGFloat = 0
        var leaves: CGFloat = 1
        // Each edge of the frame: how fast the side heads out across it, and
        // how far inside it the side starts.
        let edges = [
            (-dx, from.x - frame.minX), (dx, frame.maxX - from.x),
            (-dy, from.y - frame.minY), (dy, frame.maxY - from.y),
        ]
        for (outward, room) in edges {
            guard outward != 0 else {
                if room < 0 { return nil }
                continue
            }
            let share = room / outward
            if outward < 0 { enters = max(enters, share) } else { leaves = min(leaves, share) }
        }
        guard enters < leaves else { return nil }
        let entry = enters > 0 ? CGPoint(x: from.x + dx * enters, y: from.y + dy * enters) : from
        let exit = leaves < 1 ? CGPoint(x: from.x + dx * leaves, y: from.y + dy * leaves) : to
        return (entry, exit)
    }
}
