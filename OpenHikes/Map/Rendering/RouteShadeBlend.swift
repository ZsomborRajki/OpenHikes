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
//  tile as the flat stretches; a Core Graphics gradient clipped to each of a
//  piece's few spans (below) costs about what the flat stretches do, or less,
//  and the same at any zoom.
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
//  A piece that long bends, through switchbacks as often as not, and a linear
//  gradient colours a point by how far it lies along one straight line, not
//  how far along the route. Laid from a piece's first point to its last
//  through a hairpin, one gradient put the half-and-half mix more than a
//  hundred metres before the point the stretches share. So a piece is painted
//  in ``Span``s: cut at that shared point, and wherever else a straight
//  gradient would colour some point more than ``spanTolerance`` of the fade
//  away from where its distance along the piece puts it. The gradient is laid
//  along each span so that its colours fall where the fade has them. A
//  straight piece is two spans, one either side of the shared point.
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

    /// How far from its place in the fade a span's straight gradient may
    /// colour a point of the piece, as a share of the whole fade — see the
    /// file header. A sixteenth of the way from one colour to the other is
    /// too little to see, and keeps a piece through switchbacks to a few
    /// spans: each is a gradient of its own to draw.
    static let spanTolerance = 1.0 / 16

    /// The line either side of one change of colour.
    struct Piece {
        /// From where the blend starts in the first stretch to where it ends
        /// in the second, through the point they share.
        let points: [MKMapPoint]
        let bounds: MKMapRect
        /// ``points`` cut where one straight gradient could not follow them,
        /// in order — see the file header.
        let spans: [Span]
        /// From the first stretch's colour at the start to the second's at
        /// the end.
        let gradient: CGGradient
        /// ``gradient`` at full alpha, for recolouring a dashed or dotted
        /// line's own dashes, which keep the alpha they were drawn at — see
        /// ``DirectionalPolylineRenderer/drawBlend(_:zoomScale:context:)``.
        let opaqueGradient: CGGradient
    }

    /// A part of a piece that one straight gradient can colour.
    struct Span {
        /// The span's points, as indices into the piece's.
        let range: ClosedRange<Int>
        /// Where the piece's gradient starts and ends for this span: on the
        /// line through the span's first and last points, placed so that each
        /// of the two takes the colour of its place in the fade.
        let gradientStart: MKMapPoint
        let gradientEnd: MKMapPoint
    }

    /// One entry per pair of neighbouring `shades`, in order: the piece where
    /// the first ends and the second begins, or `nil` where they do not meet,
    /// share a colour, or have no length to fade over.
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
        let spans = spans(of: line, meeting: tail.count - 1)
        guard !spans.isEmpty else { return nil }
        let bounds = MKPolyline(points: line, count: line.count).boundingMapRect
        return Piece(points: line, bounds: bounds, spans: spans, gradient: gradient, opaqueGradient: opaqueGradient)
    }

    /// `line` in spans, cut at `meeting`, the point the stretches share —
    /// so the colour there is exactly half one and half the other — and,
    /// either side of it, wherever a straight gradient would stray from the
    /// fade by more than ``spanTolerance``. None for a line with no length.
    private static func spans(of line: [MKMapPoint], meeting: Int) -> [Span] {
        let along = line.adjacentPairs().reductions(0) { total, pair in total + distance(pair.0, pair.1) }
        guard let length = along.last, length > 0 else { return [] }
        // How far through the fade each point is.
        let fade = along.map { $0 / length }
        return spans(of: line, fade: fade, in: 0...meeting)
            + spans(of: line, fade: fade, in: meeting...(line.count - 1))
    }

    /// `line[range]` as one span if a gradient along the line from its first
    /// point to its last colours every point between close enough to its
    /// place in the fade, or else cut where that gradient strays furthest and
    /// each side tried again. A span of one segment is always straight, so
    /// the cutting ends; one with no length is dropped.
    private static func spans(of line: [MKMapPoint], fade: [Double], in range: ClosedRange<Int>) -> [Span] {
        let start = line[range.lowerBound], end = line[range.upperBound]
        let from = fade[range.lowerBound], share = fade[range.upperBound] - from
        guard share > 0 else { return [] }
        let chord = (x: end.x - start.x, y: end.y - start.y)
        let squared = chord.x * chord.x + chord.y * chord.y
        var worst: (index: Int, error: Double)?
        for index in range.dropFirst().dropLast() {
            let error: Double
            if squared > 0 {
                let point = line[index]
                let across = ((point.x - start.x) * chord.x + (point.y - start.y) * chord.y) / squared
                error = abs(from + share * across - fade[index])
            } else {
                // A span that comes back to where it started has no
                // direction for a gradient to take, so it is always cut.
                error = .infinity
            }
            if error > (worst?.error ?? spanTolerance) { worst = (index, error) }
        }
        guard let worst else {
            // The gradient runs through the whole fade, so for a span that
            // covers only `share` of it, its ends lie out beyond the span's
            // own, along the same line.
            let onChord = { (fraction: Double) in
                MKMapPoint(x: start.x + chord.x * fraction, y: start.y + chord.y * fraction)
            }
            let span = Span(
                range: range,
                gradientStart: onChord(-from / share),
                gradientEnd: onChord((1 - from) / share)
            )
            return [span]
        }
        return spans(of: line, fade: fade, in: range.lowerBound...worst.index)
            + spans(of: line, fade: fade, in: worst.index...range.upperBound)
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
