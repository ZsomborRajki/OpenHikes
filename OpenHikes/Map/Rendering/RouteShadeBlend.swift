//
//  RouteShadeBlend.swift
//  OpenHikes
//
//  Where one coloured stretch of the line meets the next, the colour slides
//  from one into the other over a short distance rather than changing at a
//  hard edge — see ``DirectionalPolylineRenderer``'s stretches.
//
//  Each stretch is still drawn flat, in its own colour, and a short *piece* of
//  line is drawn over every place two of them meet: the last ``blendMeters`` of
//  one and the first of the next, filled with a gradient from the one colour to
//  the other. Only the pieces are gradients. MapKit's own gradient renderer
//  draws the whole line as one, and measured on a 2,000-point route it took
//  fourteen times as long per tile as the flat stretches; one Core Graphics
//  gradient clipped to each piece costs less than the flat stretches do, and
//  the same at any zoom.
//
//  A piece reaches ``blendMeters`` into each side, or half of a short
//  stretch, so even the shortest stretch still shows its own colour at its
//  middle. Nothing blends across a gap, or into a stretch that does not start
//  where the last one ended.
//

import Algorithms
import CoreGraphics
import MapKit

nonisolated enum RouteShadeBlend {
    /// How far into each stretch a blend reaches from a change of colour: a
    /// quarter of the window steepness is measured over, so a stretch is mostly
    /// its own colour and the change still reads as a change.
    static let blendMeters = 25.0

    /// The line either side of one change of colour.
    struct Piece {
        /// From where the blend starts in the first stretch to where it ends
        /// in the second, through the point they share.
        let points: [MKMapPoint]
        let bounds: MKMapRect
        /// From the first stretch's colour at the start to the second's at
        /// the end.
        let gradient: CGGradient
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
              let gradient = CGGradient(
                  colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                  colors: [previous.color, next.color] as CFArray,
                  locations: [0, 1]
              )
        else { return nil }
        // In map points, the unit the line is drawn in. A hike spans too
        // little latitude for the scale to drift along one change of colour.
        let blend = blendMeters * MKMapPointsPerMeterAtLatitude(end.coordinate.latitude)
        let tail = leading(before.reversed(), reach: min(blend, length(of: before) / 2))
        let head = leading(after, reach: min(blend, length(of: after) / 2))
        let line = Array(tail.reversed() + head.dropFirst())
        guard line.count > 1 else { return nil }
        let bounds = MKPolyline(points: line, count: line.count).boundingMapRect
        return Piece(points: line, bounds: bounds, gradient: gradient)
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
