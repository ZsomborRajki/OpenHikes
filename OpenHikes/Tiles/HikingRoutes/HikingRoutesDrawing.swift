//
//  HikingRoutesDrawing.swift
//  OpenHikes
//
//  One tile of the hiking-routes layer, drawn: the lines of the squares it
//  overlaps, stroked the way ``HikingRoutesStyle`` strokes its zoom, and
//  every sign that reaches into it.
//
//  Apart from the renderer, so that what a tile looks like can be drawn into
//  any bitmap: a suite reads a line's colour back out of one, and the look
//  was set against Waymarked Trails' own by drawing a valley's tiles from
//  the squares on disk, with no map running.
//
//  Every size is in tile pixels — see ``HikingRoutesStyle`` — and a tile
//  pixel is `1 / zoomScale` map points, which is the unit the context MapKit
//  hands a renderer is in.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit

nonisolated enum HikingRoutesDrawing {
    /// A map point's width in tile pixels at zoom 0 is 2⁻²⁰: the world is
    /// 2²⁸ map points across and 256 pixels at that zoom.
    private static let zoomOfUnitScale: Double = 20
    /// How far apart two vertices have to be, in tile pixels, for both to be
    /// stroked.
    private static let minimumStep: CGFloat = 0.5
    /// How far beside a tile a sign that reaches into it can stand, in tile
    /// pixels: half the widest sign a five-character number makes.
    static let signReach: CGFloat = 24

    /// The map zoom a tile at `zoomScale` is drawn for.
    static func zoom(for zoomScale: MKZoomScale) -> Int {
        // `Int(_:)` traps on a scale no map has, and MapKit owes nobody one.
        guard zoomScale > 0, zoomScale.isFinite else { return 0 }
        return Int((log2(Double(zoomScale)) + zoomOfUnitScale).rounded())
    }

    /// The squares a tile needs: every square of its zoom's level that the
    /// tile, and a line's width or a sign's reach around it, overlaps. None
    /// where the layer draws nothing.
    static func neededSquares(for mapRect: MKMapRect, zoomScale: MKZoomScale) -> [RouteSquare] {
        let zoom = zoom(for: zoomScale)
        guard let level = RouteSquareLevel.level(forZoom: zoom) else { return [] }
        let reach = Double(max(HikingRoutesStyle.widestStroke(atZoom: zoom), signReach) / zoomScale)
        let rect = mapRect.insetBy(dx: -reach, dy: -reach).intersection(.world)
        guard !rect.isNull, !rect.isEmpty else { return [] }
        let northWest = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let southEast = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        let box = RouteSquareBounds(
            south: southEast.latitude,
            west: northWest.longitude,
            north: northWest.latitude,
            east: southEast.longitude
        )
        return RouteSquareGrid.squares(at: level, covering: box)
    }

    /// Draws the part of `squares` inside `mapRect` into `context`, which is
    /// in the renderer's points: `point` turns a map point into one.
    static func draw(
        _ squares: [DrawnRouteSquare],
        in mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        context: CGContext,
        point: (MKMapPoint) -> CGPoint
    ) {
        let zoom = zoom(for: zoomScale)
        // Map points in a tile pixel.
        let pixel = 1 / zoomScale
        strokeLines(of: squares, in: mapRect, zoom: zoom, pixel: pixel, context: context, point: point)
        drawWaymarks(of: squares, in: mapRect, zoom: zoom, pixel: pixel, context: context, point: point)
    }
}

nonisolated private extension HikingRoutesDrawing {
    /// Strokes every line near the tile, one pass a stroke of the zoom's
    /// style. The lines of each set of networks are one path, and a stroke
    /// takes every path it draws at once, so where two lines cross a
    /// translucent stroke is laid down once rather than twice.
    static func strokeLines(
        of squares: [DrawnRouteSquare],
        in mapRect: MKMapRect,
        zoom: Int,
        pixel: CGFloat,
        context: CGContext,
        point: (MKMapPoint) -> CGPoint
    ) {
        let reach = Double(HikingRoutesStyle.widestStroke(atZoom: zoom) * pixel)
        let near = mapRect.insetBy(dx: -reach, dy: -reach)
        let step = Double(minimumStep * pixel)
        var paths: [RouteNetworkSet: CGMutablePath] = [:]
        for square in squares {
            for line in square.lines where line.bounds.intersects(near) {
                let path = paths[line.networks] ?? CGMutablePath()
                paths[line.networks] = path
                add(line.points, to: path, skippingCloserThan: step, point: point)
            }
        }
        guard !paths.isEmpty else { return }

        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for stroke in HikingRoutesStyle.strokes(atZoom: zoom) {
            let drawn = paths.filter { stroke.draws($0.key) }.values
            guard !drawn.isEmpty else { continue }
            for path in drawn {
                context.addPath(path)
            }
            // Always set, solid or not: MapKit can leave a dash on the
            // context, which a solid stroke would otherwise inherit.
            context.setLineDash(phase: 0, lengths: stroke.dash.map { $0 * pixel })
            context.setLineWidth(stroke.width * pixel)
            context.setStrokeColor(stroke.color)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Draws each sign that reaches into the tile, from the list its square
    /// placed for this zoom — the same list every tile draws from, so a sign
    /// across two tiles is whole.
    static func drawWaymarks(
        of squares: [DrawnRouteSquare],
        in mapRect: MKMapRect,
        zoom: Int,
        pixel: CGFloat,
        context: CGContext,
        point: (MKMapPoint) -> CGPoint
    ) {
        for square in squares {
            for mark in square.waymarks(atZoom: zoom) {
                let size = square.signSizes[mark.sign]
                let width = Double(size.width * pixel), height = Double(size.height * pixel)
                let frame = MKMapRect(
                    x: mark.center.x - width / 2,
                    y: mark.center.y - height / 2,
                    width: width,
                    height: height
                )
                guard frame.intersects(mapRect) else { continue }
                context.saveGState()
                let center = point(mark.center)
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: pixel, y: pixel)
                square.signs[mark.sign].draw(in: context)
                context.restoreGState()
            }
        }
    }

    /// `points` as a subpath, leaving out each vertex closer than `step` to
    /// the last one kept — on either axis, which is cheaper than a distance
    /// and as good at telling a pixel's worth — and always keeping the last,
    /// so joined lines still meet. Zoomed out, most of a line's vertices are
    /// inside one pixel, and stroking them is the cost of a tile.
    static func add(
        _ points: [MKMapPoint],
        to path: CGMutablePath,
        skippingCloserThan step: Double,
        point: (MKMapPoint) -> CGPoint
    ) {
        guard let first = points.first, let last = points.last else { return }
        path.move(to: point(first))
        var kept = first
        for vertex in points.dropFirst().dropLast()
        where abs(vertex.x - kept.x) >= step || abs(vertex.y - kept.y) >= step {
            path.addLine(to: point(vertex))
            kept = vertex
        }
        path.addLine(to: point(last))
    }
}
