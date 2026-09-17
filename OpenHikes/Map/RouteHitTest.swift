//
//  RouteHitTest.swift
//  OpenHikes
//
//  Which line a thumb landed on.
//
//  MapKit has no notion of tapping an overlay: annotations are views and get
//  taps for free, and a polyline is drawn pixels. So the map's tap recognizer
//  has to answer the question itself — and the question is *which line is
//  nearest, and is it near enough to have been meant*.
//
//  Asked about two kinds of line, which is why this knows about neither. The
//  hiker's own selected route is one of them and the shared hikes around it
//  are the rest; what they have in common is a list of points and a thumb, and
//  that is the whole of what is here. Who wins when a thumb is near both is
//  ``MapView/Coordinator/routeTapTarget(at:in:)``, not this.
//
//  ## Why screen space, and why that is not an approximation
//
//  The tolerance is the only number here anybody can reason about, and it is a
//  number about thumbs: roughly the radius of a fingertip, which is a distance
//  on the glass and not on the ground. Measuring in map points would make the
//  same tolerance mean forty metres at one zoom and four kilometres at
//  another, and would have to be converted back into screen units to stay
//  honest anyway. So the caller projects each line's points through the map
//  once and the maths happens where the tolerance already lives.
//
//  Map-point space was measured as the cheaper alternative and refused. It is
//  exact under rotation and wrong under pitch — 48% off at the screen edges of
//  a tilted camera, which is two fingertips — and a hit-test that quietly
//  stops working when the map is tilted is worse than one that costs the 2.2
//  ms the projection was measured at. See
//  ``MapView/Coordinator/routeTapTarget(at:in:)`` for the guard that keeps an
//  ordinary miss from paying it.
//
//  ## Nearest rather than first
//
//  Two lines sharing a valley floor overlap on screen at any zoom that shows
//  both, and the hiker aiming at one of them is aiming at the pixels under
//  their thumb rather than at whichever the query returned first. So every
//  line within tolerance is measured and the closest wins; ordering decides
//  nothing.
//

import CoreGraphics

/// Point-to-polyline distance in screen points, and the pick that follows
/// from it.
nonisolated enum RouteHitTest {
    /// The index of the line nearest `point`, or `nil` when none is within
    /// `tolerance`.
    ///
    /// - Parameter lines: Each line's points, already projected into the same
    ///   coordinate space as `point`.
    static func nearest(
        to point: CGPoint,
        among lines: [[CGPoint]],
        tolerance: CGFloat
    ) -> Int? {
        var best: Int?
        var bestDistance = tolerance
        for (index, line) in lines.enumerated() {
            guard let distance = distance(from: point, to: line) else { continue }
            // `<=` on the first comparison and `<` after it: a line exactly on
            // the tolerance is a hit, and a later line exactly as close as an
            // earlier one does not take it from it.
            guard distance <= bestDistance, best == nil || distance < bestDistance else { continue }
            best = index
            bestDistance = distance
        }
        return best
    }

    /// How far `point` is from the nearest part of `line`, or `nil` for a line
    /// with nothing in it.
    ///
    /// A single point is a distance to that point rather than nothing: a
    /// one-point line is degenerate, but it is still somewhere, and refusing
    /// to measure it would be a special case with no behaviour behind it.
    static func distance(from point: CGPoint, to line: [CGPoint]) -> CGFloat? {
        guard let first = line.first else { return nil }
        guard line.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var nearest = CGFloat.greatestFiniteMagnitude
        for index in 1..<line.count {
            nearest = min(
                nearest,
                distance(from: point, toSegmentFrom: line[index - 1], to: line[index])
            )
        }
        return nearest
    }

    /// How far `point` is from the segment between `start` and `end`.
    ///
    /// Clamped to the segment rather than to the infinite line through it,
    /// which is the difference between a tap beyond the end of a trail
    /// counting as a tap on the trail and not.
    static func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let run = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let lengthSquared = run.x * run.x + run.y * run.y
        // A zero-length segment — two projected points landing on the same
        // pixel, which any zoomed-out route has plenty of.
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let offset = CGPoint(x: point.x - start.x, y: point.y - start.y)
        let alongSegment = min(max((offset.x * run.x + offset.y * run.y) / lengthSquared, 0), 1)
        let closest = CGPoint(
            x: start.x + alongSegment * run.x,
            y: start.y + alongSegment * run.y
        )
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}
