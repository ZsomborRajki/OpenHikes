//
//  RouteShadeBlend.swift
//  OpenHikes
//
//  Where one coloured stretch of the line meets the next, the colour slides
//  from one into the other rather than changing at a hard edge — see
//  ``DirectionalPolylineRenderer``'s stretches.
//
//  Each stretch is still drawn flat, in its own colour, and a *piece* of line
//  is drawn over every place two of them meet: the end of one and the start of
//  the next, filled with a gradient from the one colour to the other. Only the
//  pieces are gradients. MapKit's own gradient renderer draws the whole line as
//  one, and measured on a 2,000-point route it took fourteen times as long per
//  tile as the flat stretches; one Core Graphics gradient clipped to each piece
//  costs less than the flat stretches do, and the same at any zoom.
//
//  A piece reaches ``reachShare`` of the shorter of its two stretches into
//  each of them. The same distance either side, so the colour is half one and
//  half the other exactly where the stretches meet; and a share of the shorter,
//  so neither end of a stretch gives up more than that share and every stretch
//  keeps its middle in its own colour. A share of the stretches rather than a
//  fixed distance, because a fade the renderer is to draw has to be longer than
//  the line is wide: steepness stretches are at least
//  ``RouteSteepness/minimumStretchMeters`` long, and a fixed 25 m either side
//  came to under three points of the Königssee fixture seen whole, so the
//  renderer left every one of them out and the line changed colour at hard
//  edges until it was zoomed well in. Tied to the stretches, a long climb fades
//  over a few hundred metres and a short difficulty grade over a few.
//
//  Nothing blends across a gap, or into a stretch that does not start where the
//  last one ended.
//

import Algorithms
import CoreGraphics
import MapKit

nonisolated enum RouteShadeBlend {
    /// How far into each of its two stretches a blend reaches from the point
    /// they share, as a share of the shorter one — see the file header. A
    /// quarter, so every stretch keeps at least its middle half in its own
    /// colour and a change of colour still reads as one.
    static let reachShare = 0.25

    /// The line either side of one change of colour.
    struct Piece {
        /// From where the blend starts in the first stretch to where it ends
        /// in the second, through the point they share.
        let points: [MKMapPoint]
        let bounds: MKMapRect
        /// From the first stretch's colour at the start to the second's at
        /// the end.
        let gradient: CGGradient
        /// ``gradient`` at full alpha, for recolouring a dashed or dotted
        /// line's own dashes, which keep the alpha they were drawn at — see
        /// ``DirectionalPolylineRenderer/drawBlend(_:zoomScale:context:)``.
        let opaqueGradient: CGGradient
    }

    /// One entry per pair of neighbouring `shades`, in order: the piece where
    /// the first ends and the second begins, or `nil` where they do not meet
    /// or share a colour.
    ///
    /// Positional rather than only the pieces there are, because a piece
    /// has to be drawn in its place in the route — straight after the stretch
    /// it blends into, before the next. An out-and-back trail draws its
    /// return leg over its outward one, and a blend from the outward leg
    /// painted after everything else would show through on top of it.
    static func pieces(between shades: [DirectionalPolylineRenderer.Shade]) -> [Piece?] {
        shades.adjacentPairs().map { previous, next in
            piece(from: previous, to: next)
        }
    }

    private static func piece(
        from previous: DirectionalPolylineRenderer.Shade,
        to next: DirectionalPolylineRenderer.Shade
    ) -> Piece? {
        let before = points(of: previous.polyline)
        let after = points(of: next.polyline)
        guard let end = before.last, let start = after.first, end.x == start.x, end.y == start.y,
              previous.color != next.color,
              let gradient = linearGradient(from: previous.color, to: next.color),
              let opaqueGradient = linearGradient(
                  from: previous.color.copy(alpha: 1) ?? previous.color,
                  to: next.color.copy(alpha: 1) ?? next.color
              )
        else { return nil }
        // In map points, the unit the line is drawn in, the same distance
        // into each stretch — see the file header.
        let reach = reachShare * min(length(of: before), length(of: after))
        let tail = leading(before.reversed(), reach: reach)
        let head = leading(after, reach: reach)
        let line = Array(tail.reversed() + head.dropFirst())
        guard line.count > 1 else { return nil }
        let bounds = MKPolyline(points: line, count: line.count).boundingMapRect
        return Piece(points: line, bounds: bounds, gradient: gradient, opaqueGradient: opaqueGradient)
    }

    private static func linearGradient(from start: CGColor, to end: CGColor) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [start, end] as CFArray,
            locations: [0, 1]
        )
    }

    private static func points(of polyline: MKPolyline) -> [MKMapPoint] {
        Array(UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount))
    }

    private static func length(of points: [MKMapPoint]) -> Double {
        points.adjacentPairs().reduce(0) { total, pair in total + distance(pair.0, pair.1) }
    }

    private static func distance(_ from: MKMapPoint, _ to: MKMapPoint) -> Double {
        hypot(to.x - from.x, to.y - from.y)
    }

    /// The first `reach` map points of the line through `points`, ending on
    /// a point placed exactly that far along it.
    private static func leading<Points: Collection<MKMapPoint>>(_ points: Points, reach: Double) -> [MKMapPoint] {
        var kept: [MKMapPoint] = []
        var left = reach
        for point in points {
            guard let last = kept.last else {
                kept.append(point)
                continue
            }
            let step = distance(last, point)
            if step >= left {
                let along = step > 0 ? left / step : 0
                kept.append(MKMapPoint(x: last.x + (point.x - last.x) * along, y: last.y + (point.y - last.y) * along))
                return kept
            }
            left -= step
            kept.append(point)
        }
        return kept
    }
}
