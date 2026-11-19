//
//  MeasuredPath.swift
//  OpenHikes
//
//  A line measured for the names set along it: the distance to each of its
//  points, the point at a distance, and the line that runs beside it at an
//  offset, which a name written beside its line is set along.
//

import Algorithms
import CoreGraphics

/// A polyline with the distance along it to each of its points.
nonisolated struct MeasuredPath {
    let points: [CGPoint]
    let distances: [CGFloat]

    var length: CGFloat { distances.last ?? 0 }

    init(_ points: [CGPoint]) {
        self.points = points
        distances = points.adjacentPairs().reductions(0) { distance, step in
            let (from, to) = step
            return distance + hypot(to.x - from.x, to.y - from.y)
        }
    }

    /// The point `distance` along the line, held to its ends. Looked up by
    /// bisection, which the distances allow because they never fall: a name
    /// asks for a few points for each of its letters, along lines of
    /// hundreds of points where a tile is drawn from a wider archive tile.
    func point(at distance: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard distance > 0 else { return first }
        let index = distances.partitioningIndex { $0 >= distance }
        guard index < distances.endIndex, index > 0 else { return points.last ?? first }
        let span = distances[index] - distances[index - 1]
        let fraction = span > 0 ? (distance - distances[index - 1]) / span : 0
        let from = points[index - 1]
        let to = points[index]
        return CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
    }

    /// The line as far as `distance` along it: its points up to there, and
    /// the point there. The whole line where it is no longer than that, and
    /// nothing for no distance at all.
    func prefix(_ distance: CGFloat) -> [CGPoint] {
        guard distance > 0 else { return [] }
        guard distance < length else { return points }
        let index = distances.partitioningIndex { $0 >= distance }
        return Array(points[..<index]) + [point(at: distance)]
    }

    /// The line `distance` to the side of `points`: to the right of the way
    /// they run on a picture whose y runs down, which is below a name that
    /// reads along them. Each corner is moved out along the two sides'
    /// shared slant, no further than ``sharpestMiter`` times the distance,
    /// and a stretch the move turns back on itself, inside a tight bend, is
    /// left out, so letters set along the result keep their spacing where
    /// letters shifted off the middle line would crowd or spread.
    static func offset(_ points: [CGPoint], by distance: CGFloat) -> [CGPoint] {
        let line = points.reduce(into: [CGPoint]()) { kept, point in
            if kept.last != point { kept.append(point) }
        }
        guard line.count > 1, distance != 0 else { return points }
        let sides = line.adjacentPairs().map { from, to -> CGVector in
            let run = hypot(to.x - from.x, to.y - from.y)
            return CGVector(dx: (to.x - from.x) / run, dy: (to.y - from.y) / run)
        }
        var moved: [CGPoint] = []
        for (index, point) in line.indexed() {
            let before = sides[max(index - 1, 0)]
            let after = sides[min(index, sides.count - 1)]
            // The two sides' normals, added: the slant of the corner.
            let slant = CGVector(dx: -(before.dy + after.dy), dy: before.dx + after.dx)
            let spread = max(1 + before.dx * after.dx + before.dy * after.dy, 1 / sharpestMiter)
            let corner = CGPoint(
                x: point.x + slant.dx * distance / spread,
                y: point.y + slant.dy * distance / spread
            )
            // A corner behind the last one kept, along the side leading to
            // it, would run the line backwards.
            if let last = moved.last,
               (corner.x - last.x) * before.dx + (corner.y - last.y) * before.dy <= 0 {
                continue
            }
            moved.append(corner)
        }
        return moved
    }

    /// How far a corner may be moved out, in multiples of the offset.
    private static let sharpestMiter: CGFloat = 4
}
